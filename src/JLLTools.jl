module JLLTools
using SHA, Dates, Pkg
using Pkg.Operations: registered_paths
using Pkg.Artifacts
using RegistryTools.Compress: load_versions
using BinaryBuilderBase
using Base: UUID, SHA1
using PkgLicenses

export jll_uuid, get_next_wrapper_version, init_jll_package, build_jll_package,
       rebuild_jll_package, build_project_dict

# For historical reasons, our UUIDs are generated with some rather strange constants
function bb_specific_uuid5(namespace::UUID, key::String)
    data = [reinterpret(UInt8, [namespace.value]); codeunits(key)]
    u = reinterpret(UInt128, sha1(data)[1:16])[1]
    u &= 0xffffffffffff0fff3fffffffffffffff
    u |= 0x00000000000050008000000000000000
    return UUID(u)
end
const uuid_package = UUID("cfb74b52-ec16-5bb7-a574-95d9e393895e")
# For even more interesting historical reasons, we append an extra
# "_jll" to the name of the new package before computing its UUID.
jll_uuid(name) = bb_specific_uuid5(uuid_package, "$(name)_jll")

# Julia 1.3- needs a compat shim here
if VERSION < v"1.4-"
    Pkg.Operations.registered_paths(ctx::Pkg.Types.Context, uuid::UUID) = Pkg.Operations.registered_paths(ctx.env, uuid)
end

function get_next_wrapper_version(src_name, src_version::VersionNumber)
    # If src_version already has a build_number, just return it immediately
    if src_version.build != ()
        return src_version
    end
    ctx = Pkg.Types.Context()

    # Force-update the registry here, since we may have pushed a new version recently
    update_registry(ctx)

    # If it does, we need to bump the build number up to the next value
    build_number = 0
    if any(isfile(joinpath(p, "Package.toml")) for p in registered_paths(ctx, jll_uuid("$(src_name)_jll")))
        # Find largest version number that matches ours in the registered paths
        versions = VersionNumber[]
        for path in Pkg.Operations.registered_paths(ctx, jll_uuid("$(src_name)_jll"))
            append!(versions, load_versions(joinpath(path, "Versions.toml")))
        end
        versions = filter(v -> (v.major == src_version.major) &&
                               (v.minor == src_version.minor) &&
                               (v.patch == src_version.patch) &&
                               (v.build isa Tuple{<:UInt}), versions)
        # Our build number must be larger than the maximum already present in the registry
        if !isempty(versions)
            build_number = first(maximum(versions).build) + 1
        end
    end

    # Construct build_version (src_version + build_number)
    return VersionNumber(
        src_version.major,
        src_version.minor,
        src_version.patch,
        src_version.prerelease,
        (build_number,)
    )
end


function init_jll_package(name, code_dir, deploy_repo;
                          gh_auth = Wizard.github_auth(;allow_anonymous=false),
                          gh_username = gh_get_json(DEFAULT_API, "/user"; auth=gh_auth)["login"])
    try
        # This throws if it does not exist
        GitHub.repo(deploy_repo; auth=gh_auth)
    catch e
        # If it doesn't exist, create it.
        # check whether gh_org might be a user, not an organization.
        gh_org = dirname(deploy_repo)
        isorg = GitHub.owner(gh_org; auth=gh_auth).typ == "Organization"
        owner = GitHub.Owner(gh_org, isorg)
        @info("Creating new wrapper code repo at https://github.com/$(deploy_repo)")
        try
            GitHub.create_repo(owner, basename(deploy_repo), Dict("license_template" => "mit", "has_issues" => "false"); auth=gh_auth)
        catch create_e
            # If creation failed, it could be because the repo was created in the meantime.
            # Check for that; if it still doesn't exist, then freak out.  Otherwise, continue on.
            try
                GitHub.repo(deploy_repo; auth=gh_auth)
            catch
                rethrow(create_e)
            end
        end
    end

    if !isdir(code_dir)
        # If it does exist, clone it down:
        @info("Cloning wrapper code repo from https://github.com/$(deploy_repo) into $(code_dir)")
        creds = LibGit2.UserPasswordCredential(
            deepcopy(gh_username),
            deepcopy(gh_auth.token),
        )
        try
            LibGit2.clone("https://github.com/$(deploy_repo)", code_dir; credentials=creds)
        finally
            Base.shred!(creds)
        end
    else
        # Otherwise, hard-reset to latest master:
        repo = LibGit2.GitRepo(code_dir)
        LibGit2.fetch(repo)
        origin_master_oid = LibGit2.GitHash(LibGit2.lookup_branch(repo, "origin/master", true))
        LibGit2.reset!(repo, origin_master_oid, LibGit2.Consts.RESET_HARD)
        if string(LibGit2.head_oid(repo)) != string(origin_master_oid)
            LibGit2.branch!(repo, "master", string(origin_master_oid); force=true)
        end
    end
end

function build_jll_package(src_name::String,
                           build_version::VersionNumber,
                           sources::Vector,
                           code_dir::String,
                           build_output_meta::Dict,
                           dependencies::Vector,
                           bin_path::String;
                           verbose::Bool = false,
                           lazy_artifacts::Bool = false,
                           init_block = "")
    if !Base.isidentifier(src_name)
        error("Package name \"$(src_name)\" is not a valid identifier")
    end
    # Make way, for prince artifacti
    mkpath(joinpath(code_dir, "src", "wrappers"))

    platforms = keys(build_output_meta)
    products_info = Dict{Product,Any}
    for platform in sort(collect(platforms), by = triplet)
        if verbose
            @info("Generating jll package for $(triplet(platform)) in $(code_dir)")
        end

        # Extract this platform's information.  Each of these things can be platform-specific
        # (including the set of products!) so be general here.
        tarball_name, tarball_hash, git_hash, products_info = build_output_meta[platform]

        # Add an Artifacts.toml
        artifacts_toml = joinpath(code_dir, "Artifacts.toml")
        download_info = Tuple[
            (joinpath(bin_path, basename(tarball_name)), tarball_hash),
        ]
        if platform isa AnyPlatform
            # AnyPlatform begs for a platform-independent artifact
            bind_artifact!(artifacts_toml, src_name, git_hash; download_info=download_info, force=true, lazy=lazy_artifacts)
        else
            bind_artifact!(artifacts_toml, src_name, git_hash; platform=platform, download_info=download_info, force=true, lazy=lazy_artifacts)
        end

        # Generate the platform-specific wrapper code
        open(joinpath(code_dir, "src", "wrappers", "$(triplet(platform)).jl"), "w") do io
            println(io, "# Autogenerated wrapper script for $(src_name)_jll for $(triplet(platform))")
            if !isempty(products_info)
                println(io, """
                export $(join(sort(variable_name.(first.(collect(products_info)))), ", "))
                """)
            end
            for dep in dependencies
                println(io, "using $(getname(dep))")
            end

            # The LIBPATH is called different things on different platforms
            if platform isa Windows
                LIBPATH_env = "PATH"
                LIBPATH_default = ""
                pathsep = ';'
            elseif platform isa MacOS
                LIBPATH_env = "DYLD_FALLBACK_LIBRARY_PATH"
                LIBPATH_default = "~/lib:/usr/local/lib:/lib:/usr/lib"
                pathsep = ':'
            else
                LIBPATH_env = "LD_LIBRARY_PATH"
                LIBPATH_default = ""
                pathsep = ':'
            end

            println(io, """
            ## Global variables
            PATH = ""
            LIBPATH = ""
            LIBPATH_env = $(repr(LIBPATH_env))
            LIBPATH_default = $(repr(LIBPATH_default))
            """)

            # Next, begin placing products
            function global_declaration(p::LibraryProduct, p_info::Dict)
                # A library product's public interface is a handle
                return """
                # This will be filled out by __init__()
                $(variable_name(p))_handle = C_NULL

                # This must be `const` so that we can use it with `ccall()`
                const $(variable_name(p)) = $(repr(p_info["soname"]))
                """
            end

            global_declaration(p::FrameworkProduct, p_info::Dict) = global_declaration(p.libraryproduct, p_info)

            function global_declaration(p::ExecutableProduct, p_info::Dict)
                vp = variable_name(p)
                # An executable product's public interface is a do-block wrapper function
                return """
                function $(vp)(f::Function; adjust_PATH::Bool = true, adjust_LIBPATH::Bool = true)
                    global PATH, LIBPATH
                    env_mapping = Dict{String,String}()
                    if adjust_PATH
                        if !isempty(get(ENV, "PATH", ""))
                            env_mapping["PATH"] = string(PATH, $(repr(pathsep)), ENV["PATH"])
                        else
                            env_mapping["PATH"] = PATH
                        end
                    end
                    if adjust_LIBPATH
                        LIBPATH_base = get(ENV, LIBPATH_env, expanduser(LIBPATH_default))
                        if !isempty(LIBPATH_base)
                            env_mapping[LIBPATH_env] = string(LIBPATH, $(repr(pathsep)), LIBPATH_base)
                        else
                            env_mapping[LIBPATH_env] = LIBPATH
                        end
                    end
                    withenv(env_mapping...) do
                        f($(vp)_path)
                    end
                end
                """
            end

            function global_declaration(p::FileProduct, p_info::Dict)
                return """
                # This will be filled out by __init__()
                $(variable_name(p)) = ""
                """
            end

            # Create relative path mappings that are compile-time constant, and mutable
            # mappings that are initialized by __init__() at load time.
            for (p, p_info) in sort(products_info)
                vp = variable_name(p)
                println(io, """
                # Relative path to `$(vp)`
                const $(vp)_splitpath = $(repr(splitpath(p_info["path"])))

                # This will be filled out by __init__() for all products, as it must be done at runtime
                $(vp)_path = ""

                # $(vp)-specific global declaration
                $(global_declaration(p, p_info))
                """)
            end

            if !isempty(dependencies)
                print(io,
                      """
                      # Initialize PATH and LIBPATH environment variable listings.
                      # From the list of our dependencies, generate a tuple of all the PATH and LIBPATH lists,
                      # then append them to our own.
                      foreach(p -> append!(PATH_list, p), ($(join(["$(getname(dep)).PATH_list" for dep in dependencies], ", ")),))
                      foreach(p -> append!(LIBPATH_list, p), ($(join(["$(getname(dep)).LIBPATH_list" for dep in dependencies], ", ")),))
                      """)
            end

            print(io, """
            \"\"\"
            Open all libraries
            \"\"\"
            function __init__()
                # This either calls @artifact_str(), or returns a constant string.
                calculate_artifact_dir!()
                global artifact_dir

                global PATH_list, LIBPATH_list
            """)

            for (p, p_info) in sort(products_info)
                vp = variable_name(p)

                # Initialize $(vp)_path
                println(io, """
                    global $(vp)_path = normpath(joinpath(artifact_dir, $(vp)_splitpath...))
                """)

                # If `p` is a `LibraryProduct`, dlopen() it right now!
                if p isa LibraryProduct || p isa FrameworkProduct
                    println(io, """
                        # Manually `dlopen()` this right now so that future invocations
                        # of `ccall` with its `SONAME` will find this path immediately.
                        global $(vp)_handle = dlopen($(vp)_path$(BinaryBuilderBase.dlopen_flags_str(p)))
                        push!(LIBPATH_list, dirname($(vp)_path))
                    """)
                elseif p isa ExecutableProduct
                    println(io, "    push!(PATH_list, dirname($(vp)_path))")
                elseif p isa FileProduct
                    println(io, "    global $(vp) = $(vp)_path")
                end
            end

            # Libraries shipped by Julia can be found in different directories,
            # depending on the operating system and whether Julia has been built
            # from source or it's a pre-built binary. For all OSes libraries can
            # be found in Base.LIBDIR or Base.LIBDIR/julia, on Windows they are
            # in Sys.BINDIR, so we just add everything.
            init_libpath = "joinpath(Sys.BINDIR, Base.LIBDIR, \"julia\"), joinpath(Sys.BINDIR, Base.LIBDIR)"
            if isa(platform, Windows)
                init_libpath = string("Sys.BINDIR, ", init_libpath)
            end

            print(io, """
                # Filter out duplicate and empty entries in our PATH and LIBPATH entries
                filter!(!isempty, unique!(PATH_list))
                filter!(!isempty, unique!(LIBPATH_list))
                global PATH = join(PATH_list, $(repr(pathsep)))
                global LIBPATH = join(vcat(LIBPATH_list, [$(init_libpath)]), $(repr(pathsep)))

                $(init_block)
            end  # __init__()
            """)
        end
    end

    # Generate target-demuxing main source file.
    jll_jl = """
        module $(src_name)_jll
        
        if isdefined(Base, :Experimental) && isdefined(Base.Experimental, Symbol("@optlevel"))
            @eval Base.Experimental.@optlevel 0
        end                    
                                
        if VERSION < v"1.3.0-rc4"
            # We lie a bit in the registry that JLL packages are usable on Julia 1.0-1.2.
            # This is to allow packages that might want to support Julia 1.0 to get the
            # benefits of a JLL package on 1.3 (requiring them to declare a dependence on
            # this JLL package in their Project.toml) but engage in heroic hacks to do
            # something other than actually use a JLL package on 1.0-1.2.  By allowing
            # this package to be installed (but not loaded) on 1.0-1.2, we enable users
            # to avoid splitting their package versions into pre-1.3 and post-1.3 branches
            # if they are willing to engage in the kinds of hoop-jumping they might need
            # to in order to install binaries in a JLL-compatible way on 1.0-1.2. One
            # example of this hoop-jumping being to express a dependency on this JLL
            # package, then import it within a `VERSION >= v"1.3"` conditional, and use
            # the deprecated `build.jl` mechanism to download the binaries through e.g.
            # `BinaryProvider.jl`.  This should work well for the simplest packages, and
            # require greater and greater heroics for more and more complex packages.
            error("Unable to import $(src_name)_jll on Julia versions older than 1.3!")
        end

        using Pkg, Pkg.BinaryPlatforms, Pkg.Artifacts, Libdl
        import Base: UUID

        # We put these inter-JLL-package API values here so that they are always defined, even if there
        # is no underlying wrapper held within this JLL package.
        const PATH_list = String[]
        const LIBPATH_list = String[]

        # We determine, here, at compile-time, whether our JLL package has been dev'ed and overridden
        override_dir = joinpath(dirname(@__DIR__), "override")
        if isdir(override_dir)
            function calculate_artifact_dir!()
                global artifact_dir = override_dir
            end
        else
            function calculate_artifact_dir!()
                global artifact_dir = artifact"$(src_name)"
            end
        end
        """
    if Set(platforms) == Set([AnyPlatform()])
        # We know directly the wrapper we want to include
        jll_jl *= """
            include(joinpath(@__DIR__, "wrappers", "any.jl"))
            """
    else
        jll_jl *= """
            # Load Artifacts.toml file
            artifacts_toml = joinpath(@__DIR__, "..", "Artifacts.toml")

            # Extract all platforms
            artifacts = Pkg.Artifacts.load_artifacts_toml(artifacts_toml; pkg_uuid=$(repr(jll_uuid("$(src_name)_jll"))))
            platforms = [Pkg.Artifacts.unpack_platform(e, $(repr(src_name)), artifacts_toml) for e in artifacts[$(repr(src_name))]]

            # Filter platforms based on what wrappers we've generated on-disk
            filter!(p -> isfile(joinpath(@__DIR__, "wrappers", replace(triplet(p), "arm-" => "armv7l-") * ".jl")), platforms)

            # From the available options, choose the best platform
            best_platform = select_platform(Dict(p => triplet(p) for p in platforms))

            # Silently fail if there's no binaries for this platform
            if best_platform === nothing
                @debug("Unable to load $(src_name); unsupported platform \$(triplet(platform_key_abi()))")
            else
                # Load the appropriate wrapper.  Note that on older Julia versions, we still
                # say "arm-linux-gnueabihf" instead of the more correct "armv7l-linux-gnueabihf",
                # so we manually correct for that here:
                best_platform = replace(best_platform, "arm-" => "armv7l-")
                include(joinpath(@__DIR__, "wrappers", "\$(best_platform).jl"))
            end
            """
    end
    jll_jl *= """

        end  # module $(src_name)_jll
        """


    open(joinpath(code_dir, "src", "$(src_name)_jll.jl"), "w") do io
        print(io, jll_jl)
    end

    is_yggdrasil = get(ENV, "YGGDRASIL", "false") == "true"
    # Use an Azure Pipelines environment variable to get the current commit hash
    ygg_head = is_yggdrasil ? ENV["BUILD_SOURCEVERSION"] : ""
    print_source(io, s::ArchiveSource) = println(io, "* compressed archive: ", s.url, " (SHA256 checksum: `", s.hash,"`)")
    print_source(io, s::GitSource) =     println(io, "* git repository: ", s.url, " (revision: `", s.hash,"`)")
    print_source(io, s::FileSource) =    println(io, "* file: ", s.url, " (SHA256 checksum: `", s.hash,"`)")
    function print_source(io, s::DirectorySource)
        print(io, "* files in directory, relative to originating `build_tarballs.jl`: ")
        if is_yggdrasil
            println(io, "[`", s.path, "`](https://github.com/JuliaPackaging/Yggdrasil/tree/", ygg_head, "/", ENV["PROJECT"], "/", basename(s.path), ")")
        else
            println(io, "`", s.path, "`")
        end
    end
    function print_jll(io, dep)
        depname = getname(dep)
        if is_yggdrasil
            # In this case we can easily add a direct link to the repo
            println(io, "* [`", depname, "`](https://github.com/JuliaBinaryWrappers/", depname, ".jl)")
        else
            println(io, "* `", depname, ")`")
        end
    end
    print_product(io, p::Product) = println(io, "* `", typeof(p), "`: `", variable_name(p), "`")
    # Add a README.md
    open(joinpath(code_dir, "README.md"), "w") do io
        print(io,
              """
              # `$(src_name)_jll.jl` (v$(build_version))

              This is an autogenerated package constructed using [`BinaryBuilder.jl`](https://github.com/JuliaPackaging/BinaryBuilder.jl).""")
        if is_yggdrasil
            println(io, " The originating [`build_tarballs.jl`](https://github.com/JuliaPackaging/Yggdrasil/blob/$(ygg_head)/$(ENV["PROJECT"])/build_tarballs.jl) script can be found on [`Yggdrasil`](https://github.com/JuliaPackaging/Yggdrasil/), the community build tree.")
            println(io, """

                        ## Bug Reports

                        If you have any issue, please report it to the Yggdrasil [bug tracker](https://github.com/JuliaPackaging/Yggdrasil/issues).
                        """)
        end
        println(io)
        println(io)
        println(io,"For more details about JLL packages and how to use them, see `BinaryBuilder.jl` [documentation](https://juliapackaging.github.io/BinaryBuilder.jl/dev/jll/).")
        println(io)
        if length(sources) > 0
            # `sources` can be empty, and it is for some HelloWorld examples
            println(io, """
                        ## Sources

                        The tarballs for `$(src_name)_jll.jl` have been built from these sources:""")
            println(io)
            print_source.(Ref(io), sources)
            println(io)
        end
        println(io, """
                    ## Platforms

                    `$(src_name)_jll.jl` is available for the following platforms:
                    """)
        for p in sort(collect(platforms), by = triplet)
            println(io, "* `", p, "` (`", triplet(p), "`)")
        end
        if length(dependencies) > 0
            println(io)
            println(io, """
                        ## Dependencies

                        The following JLL packages are required by `$(src_name)_jll.jl`:""")
            println(io)
            print_jll.(Ref(io), sort(dependencies, by = getname))
        end
        if length(keys(products_info)) > 0
            println(io)
            println(io, """
                        ## Products

                        The code bindings within this package are autogenerated from the following `Products`:
                        """)
            for (p, _) in sort(products_info)
                print_product(io, p)
            end
        end
    end

    # Add before the license a note about to what files this applies
    license = if isfile(joinpath(code_dir, "LICENSE"))
        # In most cases we have a file called `LICENSE`...
        strip(read(joinpath(code_dir, "LICENSE"), String))
    else
        # ...but sometimes this is missing.
        strip("MIT License\n\nCopyright (c) $(year(now()))\n" * PkgLicenses.readlicense("MIT"))
    end
    note_lines = split("""
                       The Julia source code within this repository (all files under `src/`) are
                       released under the terms of the MIT \"Expat\" License, the text of which is
                       included below.  This license does not apply to the binary package wrapped by
                       this Julia package and automatically downloaded by the Julia package manager
                       upon installing this wrapper package.  The binary package's license is shipped
                       alongside the binary itself and can be found within the
                       `share/licenses/$(src_name)` directory within its prefix.""", "\n")
    # Since this function can be called multiple times, we must make sure that
    # the note is written only once.  Do nothing it is already there.
    if !startswith(license, first(note_lines))
        open(joinpath(code_dir, "LICENSE"), "w") do io
            println.(Ref(io), note_lines)
            println(io)
            println(io, license)
        end
    end
    # We used to have a duplicate license file, remove it.
    rm(joinpath(code_dir, "LICENSE.md"); force=true)

    # Add a Project.toml
    project = build_project_dict(src_name, build_version, dependencies)
    open(joinpath(code_dir, "Project.toml"), "w") do io
        Pkg.TOML.print(io, project)
    end
end


function rebuild_jll_package(name::String, build_version::VersionNumber, sources::Vector,
                             platforms::Vector, products::Vector, dependencies::Vector,
                             download_dir::String, upload_prefix::String;
                             code_dir::String = joinpath(Pkg.devdir(), "$(name)_jll"),
                             verbose::Bool = false, lazy_artifacts::Bool = false,
                             init_block::String = "", from_scratch::Bool = true)
    # We're going to recreate "build_output_meta"
    build_output_meta = Dict()

    # Then generate a JLL package for each platform
    downloaded_files = readdir(download_dir)
    for platform in sort(collect(platforms), by = triplet)
        # Find the corresponding tarball:
        tarball_idx = findfirst([occursin(".$(triplet(platform)).", f) for f in downloaded_files])
        if tarball_idx === nothing
            error("Incomplete JLL release!  Could not find tarball for $(triplet(platform))")
        end
        tarball_path = joinpath(download_dir, downloaded_files[tarball_idx])

        # Begin reconstructing all the information we need
        tarball_hash = open(tarball_path, "r") do io
            bytes2hex(sha256(io))
        end

        # Unpack the tarball into a new location, calculate the git hash and locate() each product;
        mktempdir() do dest_prefix
            unpack(tarball_path, dest_prefix; verbose=verbose)

            git_hash = Base.SHA1(Pkg.GitTools.tree_hash(dest_prefix))
            if verbose
                @info("Calculated git tree hash $(bytes2hex(git_hash.bytes)) for $(basename(tarball_path))")
            end

            # Determine locations of each product
            products_info = Dict{Product,Any}()
            for p in products
                product_path = locate(p, Prefix(dest_prefix); platform=platform, verbose=verbose, skip_dlopen=true)
                if product_path === nothing
                    error("Unable to locate $(p) within $(dest_prefix) for $(triplet(platform))")
                end
                products_info[p] = Dict("path" => relpath(product_path, dest_prefix))
                if p isa LibraryProduct || p isa FrameworkProduct
                    products_info[p]["soname"] = something(
                        Auditor.get_soname(product_path),
                        basename(product_path),
                    )
                end
            end

            # Store all this information within build_output_meta:
            build_output_meta[platform] = (
                joinpath(upload_prefix, downloaded_files[tarball_idx]),
                tarball_hash,
                git_hash,
                products_info,
            )
        end

        # If `from_scratch` is set (the default) we clear out any old crusty code
        # before generating our new, pristine, JLL package within it.  :)
        if from_scratch
            rm(joinpath(code_dir, "src"); recursive=true, force=true)
            rm(joinpath(code_dir, "Artifacts.toml"); force=true)
        end

        # Finally, generate the full JLL package
        build_jll_package(name, build_version, sources, code_dir, build_output_meta,
                          dependencies, upload_prefix; verbose=verbose,
                          lazy_artifacts=lazy_artifacts, init_block=init_block)
    end
end


function build_project_dict(name, version, dependencies::Array{Dependency})
    function has_compat_info(d::Dependency)
        r = Pkg.Types.VersionRange()
        return isa(d.pkg.version, VersionNumber) ||
               length(d.pkg.version.ranges) != 1 ||
               d.pkg.version.ranges[1] != r
    end
    function exactly_this_version(v::VersionNumber)
        return string("=", VersionNumber(v.major, v.minor, v.patch))
    end
    function exactly_this_version(v::Pkg.Types.VersionSpec)
        if length(v.ranges) == 1 &&
           v.ranges[1].lower == v.ranges[1].upper
           return string("=", v)
       end
       return string(v)
    end
    exactly_this_version(v) = v
    project = Dict(
        "name" => "$(name)_jll",
        "uuid" => string(jll_uuid("$(name)_jll")),
        "version" => string(version),
        "deps" => Dict{String,Any}(),
        # We require at least Julia 1.3+, for Pkg.Artifacts support, but we only claim
        # Julia 1.0+ so that empty JLLs can be installed on older versions.
        "compat" => Dict{String,Any}("julia" => "1.0")
    )
    for dep in dependencies
        depname = getname(dep)
        project["deps"][depname] = string(jll_uuid(depname))
        if has_compat_info(dep)
            project["compat"][depname] = string(exactly_this_version(dep.pkg.version))
        end
    end
    # Always add Libdl and Pkg as dependencies
    stdlibs = isdefined(Pkg.Types, :stdlib) ? Pkg.Types.stdlib : Pkg.Types.stdlibs
    project["deps"]["Libdl"] = first([string(u) for (u, n) in stdlibs() if n == "Libdl"])
    project["deps"]["Pkg"] = first([string(u) for (u, n) in stdlibs() if n == "Pkg"])

    return project
end

end # module
