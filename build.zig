const std = @import("std");

const version: std.SemanticVersion = .{ .major = 1, .minor = 1, .patch = 0 };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_cli = b.option(bool, "enable_cli", "Build cli") orelse false;
    const linkage = b.option(std.builtin.LinkMode, "linkage", "Link mode") orelse .static;
    const strip = b.option(bool, "strip", "Omit debug information");
    const sanitize_thread = b.option(bool, "sanitize_thread", "Enable thread sanitizer");
    const pic = b.option(bool, "pie", "Produce Position Independent Code");

    const mod_options: std.Build.Module.CreateOptions = .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .sanitize_thread = sanitize_thread,
        .pic = pic,
    };

    const upstream = b.dependency("brotli", .{});

    const brotli_common_mod = b.createModule(mod_options);
    switch (target.result.os.tag) {
        .linux => brotli_common_mod.addCMacro("OS_LINUX", ""),
        .freebsd => brotli_common_mod.addCMacro("OS_FREEBSD", ""),
        else => if (target.result.os.tag.isDarwin()) {
            brotli_common_mod.addCMacro("OS_MACOSX", "");
        },
    }
    brotli_common_mod.addIncludePath(upstream.path("c/include"));

    const brotli_common = b.addLibrary(.{
        .linkage = linkage,
        .name = "brotlicommon",
        .root_module = brotli_common_mod,
        .version = version,
    });
    b.installArtifact(brotli_common);
    brotli_common.installHeadersDirectory(upstream.path("c/include"), "", .{
        .exclude_extensions = &.{ "encode.h", "decode.h" },
    });
    brotli_common.addCSourceFiles(.{
        .root = upstream.path("c/common"),
        .files = brotli_common_sources,
    });

    const brotli_enc = b.addLibrary(.{
        .linkage = linkage,
        .name = "brotlienc",
        .root_module = b.createModule(mod_options),
        .version = version,
    });
    b.installArtifact(brotli_enc);
    brotli_enc.linkLibrary(brotli_common);
    brotli_enc.addIncludePath(upstream.path("c/include"));
    brotli_enc.installHeadersDirectory(upstream.path("c/include"), "", .{
        .include_extensions = &.{"encode.h"},
    });
    brotli_enc.addCSourceFiles(.{
        .root = upstream.path("c/enc"),
        .files = brotli_enc_sources,
    });

    const brotli_dec = b.addLibrary(.{
        .linkage = linkage,
        .name = "brotlidec",
        .root_module = b.createModule(mod_options),
        .version = version,
    });
    b.installArtifact(brotli_dec);
    brotli_dec.linkLibrary(brotli_common);
    brotli_dec.addIncludePath(upstream.path("c/include"));
    brotli_dec.installHeadersDirectory(upstream.path("c/include"), "", .{
        .include_extensions = &.{"decode.h"},
    });
    brotli_dec.addCSourceFiles(.{
        .root = upstream.path("c/dec"),
        .files = brotli_dec_sources,
    });

    const test_step = b.step("test", "Run brotli's non-streaming tests; requires -Denable_cli");
    if (enable_cli) {
        const brotli_cli = b.addExecutable(.{
            .name = "brotli",
            .root_module = b.createModule(mod_options),
        });
        b.installArtifact(brotli_cli);
        brotli_cli.linkLibrary(brotli_common);
        brotli_cli.linkLibrary(brotli_enc);
        brotli_cli.linkLibrary(brotli_dec);
        brotli_cli.addCSourceFile(.{
            .file = upstream.path("c/tools/brotli.c"),
        });

        const diff = b.addExecutable(.{
            .name = "diff",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/diff.zig"),
            }),
        });

        // tests/compatibility_test.sh
        const compats: []const []const u8 = &.{
            "empty",
            "ukkonooa",
        };
        for (compats) |compat| {
            const run_brotli = b.addRunArtifact(brotli_cli);
            run_brotli.addFileArg(upstream.path(b.fmt("tests/testdata/{s}.compressed", .{compat})));
            run_brotli.addArg("-fdo");
            const output = run_brotli.addOutputFileArg(compat);

            const run_diff = b.addRunArtifact(diff);
            run_diff.addFileArg(upstream.path(b.fmt("tests/testdata/{s}", .{compat})));
            run_diff.addFileArg(output);
            test_step.dependOn(&run_diff.step);
        }

        // tests/roundtrip_test.sh - some test files are missing from source so I added some new ones
        const roundtrips: []const std.Build.LazyPath = &.{
            upstream.path("c/enc/encode.c"),
            upstream.path("c/common/dictionary.h"),
            upstream.path("c/dec/decode.c"),
            b.path("build.zig"),
            b.path("build.zig.zon"),
            b.path("src/diff.zig"),
            brotli_common.getEmittedBin(),
        };
        for (roundtrips) |roundtrip| {
            const qualities: []const u8 = &.{ 1, 6, 9, 11 };

            for (qualities) |quality| {
                const run_compress = b.addRunArtifact(brotli_cli);
                run_compress.addArg("-fq");
                run_compress.addArg(b.fmt("{}", .{quality}));
                run_compress.addFileArg(roundtrip);
                run_compress.addArg("-o");
                const compressed = run_compress.addOutputFileArg("testdata.br");

                const run_decompress = b.addRunArtifact(brotli_cli);
                run_decompress.addFileArg(compressed);
                run_decompress.addArg("-fdo");
                const decompressed = run_decompress.addOutputFileArg("testdata");

                const run_diff = b.addRunArtifact(diff);
                run_diff.addFileArg(roundtrip);
                run_diff.addFileArg(decompressed);
                test_step.dependOn(&run_diff.step);
            }
        }
    } else {
        test_step.dependOn(&b.addFail("-Denable_cli is required to run tests").step);
    }
}

const brotli_common_sources = &.{
    "constants.c",
    "context.c",
    "dictionary.c",
    "platform.c",
    "shared_dictionary.c",
    "transform.c",
};

const brotli_enc_sources = &.{
    "backward_references.c",
    "backward_references_hq.c",
    "bit_cost.c",
    "block_splitter.c",
    "brotli_bit_stream.c",
    "cluster.c",
    "command.c",
    "compound_dictionary.c",
    "compress_fragment.c",
    "compress_fragment_two_pass.c",
    "dictionary_hash.c",
    "encode.c",
    "encoder_dict.c",
    "entropy_encode.c",
    "fast_log.c",
    "histogram.c",
    "literal_cost.c",
    "memory.c",
    "metablock.c",
    "static_dict.c",
    "utf8_util.c",
};

const brotli_dec_sources = &.{
    "bit_reader.c",
    "decode.c",
    "huffman.c",
    "state.c",
};
