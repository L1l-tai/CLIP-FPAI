cmake_minimum_required(VERSION 3.24)

project(MatMulOPPlugin LANGUAGES C CXX)

set(TARGET_NAME MatMulOP.MatMul)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED TRUE)
set(CMAKE_EXPORT_COMPILE_COMMANDS TRUE)
set(CMAKE_COLOR_DIAGNOSTICS TRUE)

set(LIBRARY_OUTPUT_PATH ${CMAKE_BINARY_DIR})
set(EXECUTABLE_OUTPUT_PATH ${CMAKE_BINARY_DIR})

# ============================================================
# MSVC compile options
# ============================================================
add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/Zc:preprocessor>")
add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/Zc:__cplusplus>")
add_compile_options("$<$<C_COMPILER_ID:MSVC>:/utf-8>")
add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/utf-8>")

# /Zi 生成调试信息
add_compile_options("$<$<C_COMPILER_ID:MSVC>:/Zi>")
add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/Zi>")

# /permissive- 启用更严格的语法检查
add_compile_options("$<$<C_COMPILER_ID:MSVC>:/permissive->")
add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/permissive->")

# 禁用 C4244 警告
add_compile_options("$<$<C_COMPILER_ID:MSVC>:/wd4244>")
add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/wd4244>")

# ============================================================
# MSVC link options
# ============================================================
add_link_options("$<$<C_COMPILER_ID:MSVC>:/INCREMENTAL:NO>")
add_link_options("$<$<CXX_COMPILER_ID:MSVC>:/INCREMENTAL:NO>")
add_link_options("$<$<C_COMPILER_ID:MSVC>:/DEBUG>")
add_link_options("$<$<CXX_COMPILER_ID:MSVC>:/DEBUG>")

# Release 优化
add_link_options("$<$<AND:$<C_COMPILER_ID:MSVC>,$<CONFIG:Release>>:/OPT:REF>")
add_link_options("$<$<AND:$<CXX_COMPILER_ID:MSVC>,$<CONFIG:Release>>:/OPT:REF>")
add_link_options("$<$<AND:$<C_COMPILER_ID:MSVC>,$<CONFIG:Release>>:/OPT:ICF>")
add_link_options("$<$<AND:$<CXX_COMPILER_ID:MSVC>,$<CONFIG:Release>>:/OPT:ICF>")

include_directories(./modelzoo_utils)

if(WIN32)
    # Windows 操作系统
    set_property(GLOBAL PROPERTY USE_FOLDERS OFF)
    set_property(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR} PROPERTY VS_STARTUP_PROJECT ${TARGET_NAME})

    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /MD /Zi")
    set(CMAKE_EXE_LINKER_FLAGS_RELEASE "${CMAKE_EXE_LINKER_FLAGS_RELEASE} /DEBUG /OPT:REF /OPT:ICF")
    set(CMAKE_SHARED_LINKER_FLAGS_RELEASE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE} /DEBUG /OPT:REF /OPT:ICF")

    add_definitions(-DYAML_CPP_STATIC_DEFINE)

    include_directories(
        C:/IcraftMdz/ThirdParty_v0.2/Eigen-3.4.0/include
        C:/IcraftMdz/ThirdParty_v0.2/YamlCpp/include
        C:/IcraftMdz/ThirdParty_v0.2/opencv2/include
    )

    link_directories(C:/IcraftMdz/ThirdParty_v0.2/YamlCpp/lib)
    link_directories(C:/IcraftMdz/ThirdParty_v0.2/opencv2/lib)

    link_libraries(
        opencv_world455
        opencv_img_hash455
        ade
        IlmImf
        ippicvmt
        ippiw
        ittnotify
        libjpeg-turbo
        libopenjp2
        libpng
        libprotobuf
        libtiff
        libwebp
        quirc
        zlib
        yaml-cpp
    )

    link_directories(C:/Icraft/CLI/lib/x86_64-win)

    find_package(Icraft-BuyiBackend REQUIRED)
    find_package(Icraft-HostBackend REQUIRED)
    find_package(icraft-zg330backend REQUIRED)

    # ============================================================
    # MatMul 自定义 OP 动态库
    # ============================================================
    add_library(${TARGET_NAME} SHARED "")

    target_sources(${TARGET_NAME}
        PRIVATE
            matmul.cpp
            matmul.h
    )

    target_include_directories(${TARGET_NAME}
        PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}
    )

    # matmul.cpp 实现了 HostBackend 接口
    # Icraft::HostBackend 通常会公开链接 XIR / XRT
    target_link_libraries(${TARGET_NAME}
        PRIVATE
            Icraft::HostBackend
    )

endif()