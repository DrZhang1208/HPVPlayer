cmake_minimum_required(VERSION 3.5.0)
set(CMAKE_CXX_STANDARD 20)
project(mpv_wrapper)

cmake_minimum_required(VERSION 3.15)

# ------------------------------------------------------------------------------
function(download_and_verify url sha locationForArchive)
  # Check if the archive exists.
  if(EXISTS "${locationForArchive}")
    file(SHA256 "${locationForArchive}" ARCHIVE_SHA)

    # If SHA256 doesn't match, delete the archive to download again.
    if(NOT sha STREQUAL ARCHIVE_SHA)
      file(REMOVE "${locationForArchive}")
      message(STATUS "MD5 mismatch. File deleted.")
    endif()
  endif()

  # Download the archive if it doesn't exist.
  if(NOT EXISTS "${locationForArchive}")
    message(STATUS "Downloading archive from ${url}...")
    file(DOWNLOAD "${url}" "${locationForArchive}")
    message(STATUS "Downloaded archive to ${locationForArchive}.")

    # Verify SHA256 of the newly downloaded file.
    file(SHA256 "${locationForArchive}" ARCHIVE_SHA)

    if(sha STREQUAL ARCHIVE_SHA)
      message(STATUS "${locationForArchive} Verification successful.")
    else()
      message(FATAL_ERROR "${locationForArchive} Integrity check failed, please try to re-build project again.")
    endif()
  endif()
endfunction()

function(check_directory_exists_and_not_empty dir result_var)
  # Check if the directory exists
  if(EXISTS "${dir}")
    # Check if the directory is not empty
    file(GLOB dir_contents "${dir}/*")

    if(dir_contents)
      set(${result_var} TRUE PARENT_SCOPE)
    else()
      set(${result_var} FALSE PARENT_SCOPE)
      message(STATUS "Directory ${dir} exists but is empty!")
    endif()
  else()
    set(${result_var} FALSE PARENT_SCOPE)
    message(STATUS "Directory ${dir} does not exist!")
  endif()
endfunction()

# Vendored prebuilt libmpv (from libmpv-ohos-build release 20260715).
# No download at configure time: the .so is committed under mpv/libs/arm64-v8a/.
set(LIBMPV_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a/")

if(NOT EXISTS "${LIBMPV_SRC}/libmpv.so")
  message(FATAL_ERROR "libmpv.so not found in ${LIBMPV_SRC}. Place the prebuilt libmpv.so there (libmpv-ohos-build release 20260715).")
endif()
# ------------------------------------------------------------------------------

add_subdirectory(third_party/aki)
include_directories(third_party/mpv/include third_party/simdjson)

add_library(mpv_wrapper SHARED
    napi_init.cpp
    src/log.cpp
    src/log.h
    src/event.cpp
    src/property.cpp
    src/main.cpp
    src/globals.h
    src/node.cpp
    src/node.h
    third_party/simdjson/simdjson.cpp)

set(LIBS
    libace_napi.z.so
    libhilog_ndk.z.so
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a/libmpv.so)

target_link_libraries(mpv_wrapper PUBLIC ${LIBS} aki_jsbind)
