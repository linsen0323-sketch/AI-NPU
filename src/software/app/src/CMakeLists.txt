# Copyright (C) 2023 - 2025 Advanced Micro Devices, Inc.  All rights reserved.
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.16)
include(${CMAKE_SOURCE_DIR}/empty_application_example.cmake)

# Include any additional CMake files here

include(${CMAKE_CURRENT_SOURCE_DIR}/user_config.cmake)
set(APP_NAME npu100_app)
project(${APP_NAME})
# JTAG stages immutable model slots; keep SD cold-boot loading disabled.
set(AI_CAMERA_LOAD_FROM_SD OFF CACHE BOOL
    "Load model packages from SD through xilffs at cold boot" FORCE)
get_filename_component(AI_RUNTIME_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../runtime/baremetal" ABSOLUTE)
if(NOT EXISTS "${AI_RUNTIME_DIR}/npu_sd_loader.h")
    message(FATAL_ERROR "npu100 requires its local software/runtime/baremetal sources")
endif()
if(AI_CAMERA_LOAD_FROM_SD)
    list(APPEND USER_COMPILE_DEFINITIONS "AI_CAMERA_LOAD_FROM_SD=1")
    list(APPEND USER_COMPILE_SOURCES "${AI_RUNTIME_DIR}/npu_sd_loader.c" "${AI_RUNTIME_DIR}/npu_sd_hash.c")
    list(APPEND USER_INCLUDE_DIRECTORIES "${AI_RUNTIME_DIR}")
endif()

find_package(common)
enable_language(C ASM CXX)
collect(PROJECT_LIB_DEPS xilstandalone;xiltimer;xilffs)
collect(PROJECT_LIB_DEPS xil)
if(AI_CAMERA_LOAD_FROM_SD)
    # Enable xilffs in the matching standalone platform/BSP before building.
    collect(PROJECT_LIB_DEPS xilffs)
endif()
collect(PROJECT_LIB_DEPS gcc)
collect(PROJECT_LIB_DEPS c)

# Use CMAKE_LIBRARY_PATH in link_directories
link_directories(${CMAKE_LIBRARY_PATH})

collector_create (PROJECT_LIB_HEADERS "${CMAKE_CURRENT_SOURCE_DIR}")
collector_create (PROJECT_LIB_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}")

# Add subdirectory dependency if available

collector_list (_headers PROJECT_LIB_HEADERS)
collector_list (_sources PROJECT_LIB_SOURCES)

aux_source_directory(${CMAKE_CURRENT_SOURCE_DIR} current_dir_sources)
# Camera row filters/CRC/NMS run cooperatively on PS. Optimize only these new
# workers; retain the existing video's user-selected compilation settings.
set_source_files_properties(ai_camera_math.c ai_camera_models.c
    PROPERTIES COMPILE_OPTIONS "-O3;-mcpu=cortex-a9;-mfpu=neon")
list(APPEND _sources ${current_dir_sources})
list (APPEND _sources ${USER_COMPILE_SOURCES})
foreach (source ${_sources})
    get_filename_component(ext ${source} EXT)
    list(APPEND src_ext ${ext})
endforeach()

if (NOT DEFINED PROJECT_TYPE)
find_project_type ("${src_ext}" PROJECT_TYPE)
endif()

if("${PROJECT_TYPE}" STREQUAL "c++")
collect(PROJECT_LIB_DEPS stdc++)
set(CMAKE_C_COMPILER ${CMAKE_CXX_COMPILER})
endif()
collector_list (_deps PROJECT_LIB_DEPS)
list (APPEND _deps ${USER_LINK_LIBRARIES})

string (REPLACE ";" ",-l" _deps "${_deps}")
if (CMAKE_EXPORT_COMPILE_COMMANDS AND
    (NOT ${YOCTO}))
    set(CMAKE_CXX_STANDARD_INCLUDE_DIRECTORIES ${CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES})
    set(CMAKE_C_STANDARD_INCLUDE_DIRECTORIES ${CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES})
endif()
# Keep the checked-in 14 MiB private region; a generic BSP DDR linker script
# could otherwise overlap the diagnostic mailbox or noncoherent DMA slots.
if(NOT EXISTS "${USER_LINKER_SCRIPT}")
    message(FATAL_ERROR "Restore npu100 software/app/src/lscript.ld before building")
endif()
string(APPEND CMAKE_C_FLAGS ${USER_COMPILE_OPTIONS})
string(APPEND CMAKE_CXX_FLAGS ${USER_COMPILE_OPTIONS})
string(APPEND CMAKE_C_LINK_FLAGS ${USER_LINK_OPTIONS})
string(APPEND CMAKE_CXX_LINK_FLAGS ${USER_LINK_OPTIONS})
if(NOT "${_sources}" STREQUAL "")
add_dependency_on_bsp(_sources)
add_executable(${APP_NAME}.elf ${_sources})
set_target_properties(${APP_NAME}.elf PROPERTIES LINK_DEPENDS ${USER_LINKER_SCRIPT})
set(_linker_command "-Wl,-T -Wl,\"${USER_LINKER_SCRIPT}\" -L\"${CMAKE_SOURCE_DIR}/\" -L\"${CMAKE_LIBRARY_PATH}/\" -L\"${USER_LINK_DIRECTORIES}/\" -Wl,--start-group,-l${_deps} -Wl,--end-group")
target_link_libraries(${APP_NAME}.elf ${_linker_command})
target_compile_definitions(${APP_NAME}.elf PUBLIC ${USER_COMPILE_DEFINITIONS})
target_include_directories(${APP_NAME}.elf PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_include_directories(${APP_NAME}.elf PUBLIC ${USER_INCLUDE_DIRECTORIES})
print_build_info_target(${APP_NAME}.elf "${CMAKE_C_FLAGS}" "${USER_COMPILE_DEFINITIONS}" "${CMAKE_C_LINK_FLAGS}" "${_linker_command}")
print_elf_size(CMAKE_SIZE ${APP_NAME})
endif()
