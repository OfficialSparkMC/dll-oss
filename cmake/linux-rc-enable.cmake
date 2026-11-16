# Loaded via -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES (runs right after project()).
#
# CMakeLists.txt compiles src/Assets/Assets.rc as a plain source file, and the
# MSVC platform module auto-enables the RC language for cl.exe builds — but
# not for clang-cl cross builds targeting Windows from Linux. Enable it here,
# and default the RC compiler to llvm-rc when nothing was configured.
if(NOT CMAKE_RC_COMPILER)
  set(CMAKE_RC_COMPILER llvm-rc)
endif()
enable_language(RC)
