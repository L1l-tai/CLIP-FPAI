cmake_minimum_required (VERSION 3.24)

        set(TARGET_NAME Gather)
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
        #/INCREMENTAL:NO 是 MSVC 链接器的一个选项，用于禁用增量链接
        add_link_options("$<$<C_COMPILER_ID:MSVC>:/INCREMENTAL:NO>")
        add_link_options("$<$<CXX_COMPILER_ID:MSVC>:/INCREMENTAL:NO>")
        add_link_options("$<$<C_COMPILER_ID:MSVC>:/DEBUG>")
        add_link_options("$<$<CXX_COMPILER_ID:MSVC>:/DEBUG>")
        #/OPT:REF 是 MSVC 链接器的一个选项，用于进行引用消除优化
        add_link_options("$<$<AND:$<C_COMPILER_ID:MSVC>,$<CONFIG:Release>>:/OPT:REF>")
        add_link_options("$<$<AND:$<CXX_COMPILER_ID:MSVC>,$<CONFIG:Release>>:/OPT:REF>")
        #/OPT:ICF 是 MSVC 链接器的一个选项，用于进行函数节省优化（Identical Code Folding）
        add_link_options("$<$<AND:$<C_COMPILER_ID:MSVC>,$<CONFIG:Release>>:/OPT:ICF>")
        add_link_options("$<$<AND:$<CXX_COMPILER_ID:MSVC>,$<CONFIG:Release>>:/OPT:ICF>")

    set_property(GLOBAL PROPERTY USE_FOLDERS OFF)
	set_property(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR} PROPERTY VS_STARTUP_PROJECT ${TARGET_NAME}) # 设置目标项目作为启动项目
	set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /MD /Zi")
	set(CMAKE_EXE_LINKER_FLAGS_RELEASE "${CMAKE_EXE_LINKER_FLAGS_RELEASE} /DEBUG /OPT:REF /OPT:ICF")
    set(CMAKE_SHARED_LINKER_FLAGS_RELEASE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE} /DEBUG /OPT:REF /OPT:ICF")
	add_definitions(-DYAML_CPP_STATIC_DEFINE)

	find_package(Icraft-BuyiBackend REQUIRED)
	find_package(Icraft-HostBackend REQUIRED)
	find_package(icraft-zg330backend REQUIRED)

    add_library(GatherOP.Gather SHARED "")

    target_sources(GatherOP.Gather PRIVATE
            gather.cpp
    )

    # 由于源文件中实现了HostBackend和量化的的接口，需要链接相应的库
    # 整个实现中还使用了XIR和XRT的接口，但是二者已经被Icraft::HostBackend公开链接，因此可以不写
    # 完整的写法为 target_link_libraries(whatever.GroupNorm PRIVATE Icraft::HostBackend Icraft::XRT Icraft::XIR)
    target_link_libraries(GatherOP.Gather PRIVATE Icraft::HostBackend)