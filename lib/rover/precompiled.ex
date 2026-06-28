defmodule Rover.Precompiled do
  @moduledoc false
  # Resolve, download, and verify the precompiled `rover_runtime` binary for the
  # host target. Used by the `:rover_download` Mix compiler
  # (`Mix.Tasks.Compile.RoverDownload`).
  #
  # rover_runtime is a standalone executable (a port binary), not a NIF — so we
  # can't lean on `rustler_precompiled`. This module is the small port-binary
  # equivalent: at `mix compile` it fetches the right tarball from the project's
  # GitHub release into `priv/native/`, where `Rover.Runtime` already looks.
  #
  # The pure decision logic (`target/2`, `archive_name/2`, `verify/2`,
  # `decision/1`) is separated from the network/extraction side effects so it can
  # be unit-tested without hitting the network.

  @github_repo "jtippett/rover"
  @binary_name "rover_runtime"

  # Targets we publish a binary for. Must match the build matrix in
  # .github/workflows/release.yml.
  @targets ~w(
    x86_64-unknown-linux-gnu
    aarch64-unknown-linux-gnu
    aarch64-apple-darwin
  )

  @checksum_file "checksum-rover_runtime.exs"

  @doc "The list of target triples we ship binaries for."
  @spec targets() :: [String.t()]
  def targets, do: @targets

  @doc "Name of the checksum file (project-root relative)."
  @spec checksum_file() :: String.t()
  def checksum_file, do: @checksum_file

  # ── Pure: host → target triple ──────────────────────────────────────────────

  @doc """
  Map the host OS/arch to one of our supported target triples, or `:unsupported`.

  `os_type` is the `{family, name}` tuple from `:os.type/0`; `system_arch` is the
  string from `:erlang.system_info(:system_architecture)` (or a bare arch token).
  """
  @spec target(:os.type(), String.t() | charlist()) :: {:ok, String.t()} | :unsupported
  def target(
        os_type \\ :os.type(),
        system_arch \\ :erlang.system_info(:system_architecture)
      ) do
    arch =
      system_arch
      |> to_string()
      |> String.split("-")
      |> hd()
      |> normalize_arch()

    case {os_type, arch} do
      {{:unix, :darwin}, "aarch64"} -> {:ok, "aarch64-apple-darwin"}
      {{:unix, :linux}, "x86_64"} -> {:ok, "x86_64-unknown-linux-gnu"}
      {{:unix, :linux}, "aarch64"} -> {:ok, "aarch64-unknown-linux-gnu"}
      _ -> :unsupported
    end
  end

  defp normalize_arch("arm64"), do: "aarch64"
  defp normalize_arch("amd64"), do: "x86_64"
  defp normalize_arch(other), do: other

  # ── Pure: artifact naming ───────────────────────────────────────────────────

  @doc "The per-target release tarball name."
  @spec archive_name(String.t(), String.t()) :: String.t()
  def archive_name(version, target), do: "#{@binary_name}-v#{version}-#{target}.tar.gz"

  @doc "The GitHub release download URL for a target's tarball."
  @spec archive_url(String.t(), String.t()) :: String.t()
  def archive_url(version, target) do
    "https://github.com/#{@github_repo}/releases/download/v#{version}/#{archive_name(version, target)}"
  end

  # ── Pure: checksum verification ─────────────────────────────────────────────

  @doc """
  Verify `bytes` against a `"sha256:<hex>"` checksum string (the format stored in
  `#{@checksum_file}`).
  """
  @spec verify(binary(), String.t()) ::
          :ok
          | {:error,
             {:checksum_mismatch, String.t(), String.t()} | {:bad_checksum_format, String.t()}}
  def verify(bytes, "sha256:" <> expected) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    if secure_equal?(actual, expected) do
      :ok
    else
      {:error, {:checksum_mismatch, expected, actual}}
    end
  end

  def verify(_bytes, other), do: {:error, {:bad_checksum_format, other}}

  # Constant-time-ish compare (the checksums aren't secret, but cheap to be tidy).
  defp secure_equal?(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  rescue
    # hash_equals exists on OTP 25+; fall back to == otherwise.
    _ -> a == b
  end

  defp secure_equal?(_a, _b), do: false

  # ── Pure: skip/download decision ────────────────────────────────────────────

  @typedoc "Inputs gathered by the compiler before deciding what to do."
  @type inputs :: %{
          binary_present?: boolean(),
          build_env?: boolean(),
          target: {:ok, String.t()} | :unsupported,
          version: String.t(),
          checksums: %{optional(String.t()) => String.t()} | nil
        }

  @doc """
  Decide whether to download, given the gathered inputs. Checks run cheapest-first
  so an already-installed or force-build setup never touches the network.
  """
  @spec decision(inputs()) ::
          {:download, String.t(), String.t()} | {:skip, atom() | {atom(), term()}}
  def decision(%{binary_present?: true}), do: {:skip, :already_present}
  def decision(%{build_env?: true}), do: {:skip, :force_build}
  def decision(%{target: :unsupported}), do: {:skip, :unsupported_target}
  def decision(%{checksums: nil}), do: {:skip, :no_checksum_file}

  def decision(%{target: {:ok, triple}, version: version, checksums: checksums}) do
    name = archive_name(version, triple)

    case Map.fetch(checksums, name) do
      {:ok, sha} -> {:download, name, sha}
      :error -> {:skip, {:not_in_checksums, name}}
    end
  end

  @doc "Render a `name => sha` map as a sorted Elixir map literal for #{@checksum_file}."
  @spec render_checksums(%{optional(String.t()) => String.t()}) :: String.t()
  def render_checksums(map) do
    body =
      map
      |> Enum.sort()
      |> Enum.map_join("\n", fn {name, sha} -> ~s(  "#{name}" => "#{sha}",) end)

    "%{\n#{body}\n}\n"
  end

  # ── Side effects: checksum file, install, fetch, orchestration ──────────────

  @doc """
  Download a target's release tarball and return its `{archive_name, "sha256:..."}`
  entry. Used by `mix rover.runtime.download` to (re)generate the checksum file.

  The tarball is streamed to a temp file (it embeds Servo and is large), hashed,
  then deleted — it's never held in memory.
  """
  @spec fetch_checksum(String.t(), String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, {String.t(), term()}}
  def fetch_checksum(version, target) do
    name = archive_name(version, target)
    tmp = Path.join(System.tmp_dir!(), name)

    try do
      case fetch_to_file(archive_url(version, target), tmp) do
        :ok -> {:ok, {name, "sha256:" <> sha256_file(tmp)}}
        {:error, reason} -> {:error, {target, reason}}
      end
    after
      File.rm(tmp)
    end
  end

  @doc """
  Load `#{@checksum_file}` into a `name => "sha256:..."` map, or `nil` if absent.
  """
  @spec load_checksums(Path.t()) :: %{optional(String.t()) => String.t()} | nil
  def load_checksums(path) do
    if File.exists?(path) do
      {map, _bindings} = Code.eval_file(path)
      map
    else
      nil
    end
  end

  @doc """
  Verify the gzipped tarball at `path` against a `"sha256:<hex>"` checksum,
  streaming the file rather than reading it into memory.
  """
  @spec verify_file(Path.t(), String.t()) ::
          :ok
          | {:error,
             {:checksum_mismatch, String.t(), String.t()} | {:bad_checksum_format, String.t()}}
  def verify_file(path, "sha256:" <> expected) do
    actual = sha256_file(path)

    if secure_equal?(actual, expected) do
      :ok
    else
      {:error, {:checksum_mismatch, expected, actual}}
    end
  end

  def verify_file(_path, other), do: {:error, {:bad_checksum_format, other}}

  @doc """
  Extract a gzipped tarball file into `dest_dir` and mark `rover_runtime`
  executable. The release tarballs contain a single `rover_runtime` entry at the
  archive root; the sha256 is verified (against the committed checksum file)
  before this runs, so the archive's contents are trusted.
  """
  @spec install_file(Path.t(), Path.t()) :: :ok | {:error, {:extract_failed, term()}}
  def install_file(tar_path, dest_dir) do
    File.mkdir_p!(dest_dir)

    case :erl_tar.extract(String.to_charlist(tar_path), [
           :compressed,
           {:cwd, String.to_charlist(dest_dir)}
         ]) do
      :ok ->
        File.chmod(Path.join(dest_dir, @binary_name), 0o755)
        :ok

      {:error, reason} ->
        {:error, {:extract_failed, reason}}
    end
  end

  @doc """
  Ensure the precompiled `rover_runtime` is present under the app's
  `priv/native`, downloading and verifying it if needed.

  Returns `{:ok, archive}` on a fresh install, `{:skip, reason}` when no download
  is needed (or possible), or `{:error, {archive, reason}}` on a download/verify
  failure. Options (all defaulted) let callers and tests pin the inputs:
  `:root`, `:version`, `:build_env?`, `:target`.

  The default `:root` is `Mix.Project.app_path()` — the build dir
  (`_build/<env>/lib/rover`) that `:code.priv_dir(:rover)` resolves at runtime. The
  binary must land there (not in the source tree) so it survives `mix release` and
  is found when Rover is a dependency.
  """
  @spec ensure(keyword()) ::
          {:ok, String.t()} | {:skip, term()} | {:error, {String.t(), term()}}
  def ensure(opts \\ []) do
    root = Keyword.get(opts, :root) || Mix.Project.app_path()
    version = Keyword.get(opts, :version) || Mix.Project.config()[:version]
    dest_dir = Path.join([root, "priv", "native"])

    inputs = %{
      binary_present?: File.exists?(Path.join(dest_dir, @binary_name)),
      build_env?: Keyword.get(opts, :build_env?, build_env_set?()),
      target: Keyword.get(opts, :target, target()),
      version: version,
      # The checksum file ships at the package root, which is the project root at
      # compile time — not the build dir. Resolve it from cwd unless overridden.
      checksums: load_checksums(Path.join(Keyword.get(opts, :root, File.cwd!()), @checksum_file))
    }

    case decision(inputs) do
      {:skip, reason} ->
        {:skip, reason}

      {:download, name, sha} ->
        {:ok, triple} = inputs.target
        url = archive_url(version, triple)
        tmp = Path.join(System.tmp_dir!(), name)

        try do
          with :ok <- fetch_to_file(url, tmp),
               :ok <- verify_file(tmp, sha),
               :ok <- install_file(tmp, dest_dir) do
            {:ok, name}
          else
            {:error, reason} -> {:error, {name, reason}}
          end
        after
          File.rm(tmp)
        end
    end
  end

  # ROVER_BUILD=1 (or any non-empty/non-"0"/"false" value) → skip the download and
  # use a local `cargo` build instead. Used by the library's own dev/test/CI.
  defp build_env_set? do
    System.get_env("ROVER_BUILD") not in [nil, "", "0", "false"]
  end

  defp sha256_file(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # Stream the response body straight to `dest` so we never hold the (large,
  # Servo-embedding) binary in the compiler's heap.
  @spec fetch_to_file(String.t(), Path.t()) :: :ok | {:error, term()}
  defp fetch_to_file(url, dest) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    with {:ok, cacerts} <- cacerts() do
      http_opts = [
        autoredirect: true,
        # connect ceiling is short; the body transfer ceiling is generous because
        # the artifact is hundreds of MB on a slow link.
        connect_timeout: 30_000,
        timeout: 600_000,
        ssl: [
          verify: :verify_peer,
          cacerts: cacerts,
          depth: 3,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]

      request = {String.to_charlist(url), []}

      case :httpc.request(:get, request, http_opts, stream: String.to_charlist(dest)) do
        {:ok, :saved_to_file} -> :ok
        {:ok, {{_v, status, _r}, _headers, _body}} -> {:error, {:http_status, status}}
        {:error, reason} -> {:error, {:http_error, reason}}
      end
    end
  end

  # :public_key.cacerts_get/0 raises when no system CA store is usable; surface
  # that as an error so the compiler reports it cleanly instead of crashing.
  defp cacerts do
    {:ok, :public_key.cacerts_get()}
  rescue
    e -> {:error, {:cacerts_unavailable, Exception.message(e)}}
  end
end
