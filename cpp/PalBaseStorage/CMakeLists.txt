cmake_minimum_required(VERSION 3.22)
set(TARGET PalBaseStorage)
project(${TARGET})

add_library(${TARGET} SHARED
        src/dllmain.cpp
)

target_link_libraries(${TARGET} PUBLIC UE4SS)
target_compile_options(${TARGET} PRIVATE /utf-8)
