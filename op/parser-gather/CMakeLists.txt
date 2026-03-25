cmake_minimum_required (VERSION 3.24)

    set(TARGET_NAME Parser)
    set(CMAKE_CXX_STANDARD 17)
    set(CMAKE_CXX_STANDARD_REQUIRED TRUE)
    set(CMAKE_EXPORT_COMPILE_COMMANDS TRUE)
    set(CMAKE_COLOR_DIAGNOSTICS TRUE)

    set(LIBRARY_OUTPUT_PATH ${CMAKE_BINARY_DIR})
    set(EXECUTABLE_OUTPUT_PATH ${CMAKE_BINARY_DIR})
    add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/Zc:preprocessor>")
    add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/Zc:__cplusplus>")
    add_compile_options("$<$<C_COMPILER_ID:MSVC>:/utf-8>")
    add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/utf-8>")
    #/Zi 是 MSVC 编译器的一个选项，用于生成调试信息
    add_compile_options("$<$<C_COMPILER_ID:MSVC>:/Zi>")
    add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/Zi>")
    #/permissive- 用于启用更严格的语法检查和符合性检查
    add_compile_options("$<$<C_COMPILER_ID:MSVC>:/permissive->")
    add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/permissive->")
    #/wd4244 是 MSVC 编译器的一个选项，用于禁止特定的警告
    add_compile_options("$<$<C_COMPILER_ID:MSVC>:/wd4244>")
    add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/wd4244>")
   
    link_directories(C:/Icraft/CLI/lib/x86_64-win)

	find_package(Icraft-BuyiBackend REQUIRED)
	find_package(Icraft-HostBackend REQUIRED)
	find_package(icraft-zg330backend REQUIRED)

    #protobuf的安装路径
    set(PROTC_PACKAGE_PATH "D:/protobuf-3.21.12")
    set(CMAKE_PREFIX_PATH ${PROTC_PACKAGE_PATH}/cmake/build/cmake)
    message(STATUS "CMAKE_PREFIX_PATH: " ${CMAKE_PREFIX_PATH})
    find_package(protobuf CONFIG REQUIRED)

    add_library(icraft.parse.gather SHARED "")

    target_sources(icraft.parse.gather PRIVATE
            parser.cpp
            onnx.proto3.pb.cc
     )

    target_link_libraries(icraft.parse.gather PRIVATE Icraft::HostBackend icraft_onnx_opset11lib protobuf::libprotobuf)
