cmake_minimum_required(VERSION 3.14)

option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)
set(PROJECT_NAME "media_kit_libs_windows_video")
project(${PROJECT_NAME} LANGUAGES CXX)
add_compile_definitions(_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8 OR FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  message(FATAL_ERROR "The pinned media libraries require Windows x64.")
endif()

function(duanju_native_archive filename url digest destination)
  set(archive "${CMAKE_BINARY_DIR}/${filename}")
  if(EXISTS "${archive}")
    file(SHA256 "${archive}" actual_digest)
    if(NOT actual_digest STREQUAL digest)
      file(REMOVE "${archive}")
    endif()
  endif()
  if(NOT EXISTS "${archive}")
    file(DOWNLOAD "${url}" "${archive}"
      EXPECTED_HASH "SHA256=${digest}"
      TLS_VERIFY ON
      TIMEOUT 300
      INACTIVITY_TIMEOUT 45
      STATUS download_status
    )
    list(GET download_status 0 download_code)
    if(NOT download_code EQUAL 0)
      file(REMOVE "${archive}")
      message(FATAL_ERROR "Failed to download ${filename}: ${download_status}")
    endif()
  endif()

  set(valid FALSE)
  if(EXISTS "${destination}/.duanju-sha256")
    file(READ "${destination}/.duanju-sha256" extracted_digest)
    if(extracted_digest STREQUAL digest)
      set(valid TRUE)
    endif()
  endif()
  foreach(required IN LISTS ARGN)
    if(NOT EXISTS "${destination}/${required}")
      set(valid FALSE)
    endif()
  endforeach()
  if(NOT valid)
    file(REMOVE_RECURSE "${destination}")
    file(MAKE_DIRECTORY "${destination}")
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E tar xf "${archive}"
      WORKING_DIRECTORY "${destination}"
      RESULT_VARIABLE extract_result
    )
    if(NOT extract_result EQUAL 0)
      message(FATAL_ERROR "Failed to extract ${filename}")
    endif()
    foreach(required IN LISTS ARGN)
      if(NOT EXISTS "${destination}/${required}")
        message(FATAL_ERROR "${filename} is missing ${required}")
      endif()
    endforeach()
    file(WRITE "${destination}/.duanju-sha256" "${digest}")
  endif()
endfunction()

set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv")
duanju_native_archive(
  "mpv-dev-x86_64-20261103-git-a687796d9d.7z"
  "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261103/mpv-dev-x86_64-20261103-git-a687796d9d.7z"
  "41cbfda596aaf1dc30053679bcd22828afaeec411340de6bf4c0e786fed1480b"
  "${LIBMPV_SRC}"
  "libmpv-2.dll" "libmpv.dll.a" "include/mpv/client.h" "include/mpv/render.h"
)
file(COPY "${LIBMPV_SRC}/include/mpv/" DESTINATION "${LIBMPV_SRC}/include")

set(ANGLE_SRC "${CMAKE_BINARY_DIR}/ANGLE")
duanju_native_archive(
  "ANGLE-v1.0.1.7z"
  "https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z"
  "cc5911bb15d596fd5a2b362613ad35b7093b427117269a7359054a65746a5f9a"
  "${ANGLE_SRC}"
  "include/EGL/egl.h" "lib/libEGL.dll.lib" "lib/libGLESv2.dll.lib"
  "d3dcompiler_47.dll" "libc++.dll" "libEGL.dll" "libGLESv2.dll"
  "vk_swiftshader.dll" "vulkan-1.dll" "zlib.dll"
)

set(PLUGIN_NAME "media_kit_libs_windows_video_plugin")
add_library(${PLUGIN_NAME} SHARED
  "include/media_kit_libs_windows_video/media_kit_libs_windows_video_plugin_c_api.h"
  "media_kit_libs_windows_video_plugin_c_api.cpp"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

set(media_kit_libs_windows_video_bundled_libraries
  "${LIBMPV_SRC}/libmpv-2.dll"
  "${ANGLE_SRC}/d3dcompiler_47.dll"
  "${ANGLE_SRC}/libc++.dll"
  "${ANGLE_SRC}/libEGL.dll"
  "${ANGLE_SRC}/libGLESv2.dll"
  "${ANGLE_SRC}/vk_swiftshader.dll"
  "${ANGLE_SRC}/vulkan-1.dll"
  "${ANGLE_SRC}/zlib.dll"
  PARENT_SCOPE
)
