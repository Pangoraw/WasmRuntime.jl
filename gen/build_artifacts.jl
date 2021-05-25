import Downloads
using GitHub
using Pkg.Artifacts
using Base.BinaryPlatforms
using Tar

const gh_auth = GitHub.AnonymousAuth()

function make_artifacts(dir)
    release = latest_release("bytecodealliance/wasmtime"; auth=gh_auth)
    release_version = VersionNumber(release.tag_name)

    platforms = [
        Platform("x86_64", "linux"; libc="glibc"),
    ]

    tripletnolibc(platform) = replace(triplet(platform), "-gnu" => "")
    wasmtime_asset_name(platform) =
        "wasmtime-v$release_version-$(tripletnolibc(platform))-c-api.tar.xz"
    asset_names = wasmtime_asset_name.(platforms)

    assets = filter(asset -> asset["name"] ∈ asset_names, release.assets)
    artifacts_toml = joinpath(@__DIR__, "Artifacts.toml")

    for (platform, asset) in zip(platforms, assets)
        archive_location = joinpath(dir, asset["name"])
        download_url = asset["browser_download_url"]
        Downloads.download(download_url, archive_location;
            progress=(t,n) -> print("$(floor(100*n/t))%\r"))
        println()

        artifact_hash = create_artifact() do artifact_dir
            run(`tar -xvf $archive_location -C $artifact_dir`)
        end

        # TODO: replace with real hash
        download_hash = archive_artifact(artifact_hash, joinpath(@__DIR__, "build.tar.xz"))
        bind_artifact!(artifacts_toml, "libwasmtime", artifact_hash; platform, force=true, download_info=[
            (download_url, download_hash)
        ])
    end
end

main() = mktempdir(make_artifacts) 