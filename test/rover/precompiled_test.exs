defmodule Rover.PrecompiledTest do
  use ExUnit.Case, async: true

  alias Rover.Precompiled

  describe "target/2" do
    test "maps the three supported hosts to their target triples" do
      assert Precompiled.target({:unix, :darwin}, "aarch64-apple-darwin23.6.0") ==
               {:ok, "aarch64-apple-darwin"}

      assert Precompiled.target({:unix, :linux}, "x86_64-pc-linux-gnu") ==
               {:ok, "x86_64-unknown-linux-gnu"}

      assert Precompiled.target({:unix, :linux}, "aarch64-unknown-linux-gnu") ==
               {:ok, "aarch64-unknown-linux-gnu"}
    end

    test "normalizes arm64/amd64 arch spellings" do
      assert Precompiled.target({:unix, :darwin}, "arm64-apple-darwin") ==
               {:ok, "aarch64-apple-darwin"}

      assert Precompiled.target({:unix, :linux}, "amd64") ==
               {:ok, "x86_64-unknown-linux-gnu"}
    end

    test "returns :unsupported for hosts we don't ship" do
      # We don't build an Intel-mac runtime (Servo x86_64-darwin is deprecated).
      assert Precompiled.target({:unix, :darwin}, "x86_64-apple-darwin") == :unsupported
      assert Precompiled.target({:win32, :nt}, "x86_64") == :unsupported
      assert Precompiled.target({:unix, :freebsd}, "x86_64") == :unsupported
    end
  end

  describe "archive_name/2 and archive_url/2" do
    test "builds the per-target tarball name" do
      assert Precompiled.archive_name("0.1.0", "x86_64-unknown-linux-gnu") ==
               "rover_runtime-v0.1.0-x86_64-unknown-linux-gnu.tar.gz"
    end

    test "builds the GitHub release download URL" do
      assert Precompiled.archive_url("0.2.3", "aarch64-apple-darwin") ==
               "https://github.com/jtippett/rover/releases/download/" <>
                 "v0.2.3/rover_runtime-v0.2.3-aarch64-apple-darwin.tar.gz"
    end
  end

  describe "verify/2" do
    test "accepts matching sha256" do
      bytes = "the binary bytes"
      sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      assert Precompiled.verify(bytes, "sha256:" <> sha) == :ok
    end

    test "rejects a mismatch" do
      assert {:error, {:checksum_mismatch, _, _}} =
               Precompiled.verify("bytes", "sha256:deadbeef")
    end

    test "rejects an unparseable checksum" do
      assert {:error, {:bad_checksum_format, "md5:whatever"}} =
               Precompiled.verify("bytes", "md5:whatever")
    end
  end

  describe "decision/1" do
    @version "0.1.0"
    @triple "x86_64-unknown-linux-gnu"
    @name "rover_runtime-v0.1.0-x86_64-unknown-linux-gnu.tar.gz"
    @checksums %{@name => "sha256:abc123"}

    defp inputs(overrides) do
      Map.merge(
        %{
          binary_present?: false,
          build_env?: false,
          target: {:ok, @triple},
          version: @version,
          checksums: @checksums
        },
        Map.new(overrides)
      )
    end

    test "downloads when everything is in place" do
      assert Precompiled.decision(inputs([])) == {:download, @name, "sha256:abc123"}
    end

    test "skips when the binary is already present (cheapest check wins)" do
      assert Precompiled.decision(inputs(binary_present?: true)) == {:skip, :already_present}
    end

    test "skips when ROVER_BUILD forces a local build" do
      assert Precompiled.decision(inputs(build_env?: true)) == {:skip, :force_build}
    end

    test "skips on an unsupported host" do
      assert Precompiled.decision(inputs(target: :unsupported)) == {:skip, :unsupported_target}
    end

    test "skips when no checksum file is present (unreleased dev version)" do
      assert Precompiled.decision(inputs(checksums: nil)) == {:skip, :no_checksum_file}
    end

    test "skips when this target isn't in the checksum file" do
      assert {:skip, {:not_in_checksums, @name}} =
               Precompiled.decision(
                 inputs(checksums: %{"some-other-target.tar.gz" => "sha256:x"})
               )
    end

    test "an already-present binary wins even with force_build set" do
      assert Precompiled.decision(inputs(binary_present?: true, build_env?: true)) ==
               {:skip, :already_present}
    end
  end

  describe "load_checksums/1" do
    @tag :tmp_dir
    test "evaluates the checksum file into a map", %{tmp_dir: dir} do
      path = Path.join(dir, "checksum-rover_runtime.exs")

      File.write!(
        path,
        ~s(%{\n  "rover_runtime-v0.1.0-x86_64-unknown-linux-gnu.tar.gz" => "sha256:abc"\n}\n)
      )

      assert Precompiled.load_checksums(path) == %{
               "rover_runtime-v0.1.0-x86_64-unknown-linux-gnu.tar.gz" => "sha256:abc"
             }
    end

    test "returns nil when the file is absent" do
      assert Precompiled.load_checksums("/no/such/checksum.exs") == nil
    end
  end

  describe "install_file/2 and verify_file/2" do
    @tag :tmp_dir
    test "verifies a tarball's sha256 then extracts rover_runtime as executable",
         %{tmp_dir: dir} do
      # Build a .tar.gz containing a single `rover_runtime` entry.
      src = Path.join(dir, "rover_runtime")
      File.write!(src, "#!/bin/sh\necho hi\n")
      tarball = Path.join(dir, "pkg.tar.gz")

      :ok =
        :erl_tar.create(
          String.to_charlist(tarball),
          [{~c"rover_runtime", String.to_charlist(src)}],
          [:compressed]
        )

      sha = :crypto.hash(:sha256, File.read!(tarball)) |> Base.encode16(case: :lower)
      assert Precompiled.verify_file(tarball, "sha256:" <> sha) == :ok

      assert {:error, {:checksum_mismatch, _, _}} =
               Precompiled.verify_file(tarball, "sha256:dead")

      assert {:error, {:bad_checksum_format, "md5:x"}} = Precompiled.verify_file(tarball, "md5:x")

      dest = Path.join(dir, "native")
      assert :ok = Precompiled.install_file(tarball, dest)

      installed = Path.join(dest, "rover_runtime")
      assert File.read!(installed) == "#!/bin/sh\necho hi\n"
      assert {:ok, %File.Stat{mode: mode}} = File.stat(installed)
      assert Bitwise.band(mode, 0o111) != 0, "expected the installed binary to be executable"
    end
  end

  describe "render_checksums/1" do
    test "renders a sorted Elixir map literal that load_checksums round-trips" do
      map = %{
        "rover_runtime-v0.1.0-x86_64-unknown-linux-gnu.tar.gz" => "sha256:bbb",
        "rover_runtime-v0.1.0-aarch64-apple-darwin.tar.gz" => "sha256:aaa"
      }

      rendered = Precompiled.render_checksums(map)

      # Sorted by key (aarch64 before x86_64).
      assert rendered =~
               ~r/aarch64-apple-darwin.*x86_64-unknown-linux-gnu/s

      {parsed, _} = Code.eval_string(rendered)
      assert parsed == map
    end
  end

  describe "ensure/1 (no network on skip paths)" do
    @tag :tmp_dir
    test "skips when the binary is already in priv/native", %{tmp_dir: dir} do
      native = Path.join([dir, "priv", "native"])
      File.mkdir_p!(native)
      File.write!(Path.join(native, "rover_runtime"), "binary")

      assert Precompiled.ensure(root: dir, version: "9.9.9") == {:skip, :already_present}
    end

    @tag :tmp_dir
    test "skips when there is no checksum file (unreleased dev version)", %{tmp_dir: dir} do
      # Pin build_env?/target so the result doesn't depend on the test host or the
      # ROVER_BUILD=1 we run the suite under.
      assert Precompiled.ensure(
               root: dir,
               version: "9.9.9",
               build_env?: false,
               target: {:ok, "x86_64-unknown-linux-gnu"}
             ) == {:skip, :no_checksum_file}
    end
  end
end
