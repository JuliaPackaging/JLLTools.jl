using Test, JLLTools
using Base: UUID, SHA1
using BinaryBuilderBase
using Pkg

@testset "Utilities" begin
    @test jll_uuid("Zlib_jll") == UUID("83775a58-1f1d-513f-b197-d71354ab007a")
    @test jll_uuid("FFMPEG_jll") == UUID("b22a6f82-2f65-5046-a5b2-351ab43fb4e5")

    project = build_project_dict("LibFoo", v"1.3.5", [Dependency("Zlib_jll"), Dependency(PackageSpec(name = "XZ_jll", version = v"2.4.6"))])
    @test project["deps"] == Dict("Pkg"      => "44cfe95a-1eb2-52ea-b672-e2afdf69b78f",
                                  "Zlib_jll" => "83775a58-1f1d-513f-b197-d71354ab007a",
                                  "Libdl"    => "8f399da3-3557-5675-b5ff-fb832c97cbdb",
                                  "XZ_jll"   => "ffd25f8a-64ca-5728-b0f7-c24cf3aae800")
    @test project["name"] == "LibFoo_jll"
    @test project["uuid"] == "b250f842-3251-58d3-8ee4-9a24ab2bab3f"
    @test project["compat"] == Dict("julia" => "1.0", "XZ_jll" => "=2.4.6")
    @test project["version"] == "1.3.5"
    # Make sure BuildDependency's don't find their way to the project
    @test_throws MethodError build_project_dict("LibFoo", v"1.3.5", [Dependency("Zlib_jll"), BuildDependency("Xorg_util_macros_jll")])
end

module TestJLL end
@testset "JLL building" begin
    mktempdir() do code_dir
        # Recreate HelloWorldC_jll for linux64 and macos64
        build_output_meta = Dict()
        build_output_meta[Linux(:x86_64)] = (
            "HelloWorldC.v1.0.10.x86_64-linux-gnu.tar.gz",
            "313fb164fd2d558c7d3ced63126ed8c394acea4e60a74d13d46738716cfe1f3b",
            SHA1("8e06967e4a994705f22d0719360ea2d304a9de82"),
            Dict{Product,Any}(
                ExecutableProduct("hello_world", :hello_world) => Dict("path" => "bin/hello_world"),
            ),
        )
        build_output_meta[MacOS()] = (
            "HelloWorldC.v1.0.10.x86_64-apple-darwin14.tar.gz",
            "762d64b743ffe66fc9d1e4094b703f69193171cd70740394cdb58ff3079b8c3b",
            SHA1("f1d6a7bc4a7ba064dcb5aafac978e9b9370ca76e"),
            Dict{Product,Any}(
                ExecutableProduct("hello_world", :hello_world) => Dict("path" => "bin/hello_world"),
            ),
        )
        build_jll_package(
            "HelloWorldC",
            v"1.0.10+0",
            [DirectorySource("./bundled")],
            code_dir,
            build_output_meta,
            Dependency[],
            "https://github.com/JuliaBinaryWrappers/HelloWorldC_jll.jl/releases/download/HelloWorldC-v1.0.10+0",
        )
        @test isfile(joinpath(code_dir, "README.md"))
        @test isfile(joinpath(code_dir, "LICENSE"))
        @test isfile(joinpath(code_dir, "Project.toml"))
        @test isdir(joinpath(code_dir, "src"))

        mktempdir() do env_dir
            Pkg.activate(env_dir)
            Pkg.develop(PackageSpec(path=code_dir))
            @eval TestJLL using HelloWorldC_jll
            @test "Hello, World!" == @eval TestJLL hello_world(p -> strip(String(read(`$p`))))
        end
    end
end