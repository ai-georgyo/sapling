# Included from the top-level CMakeLists.txt by nix/edenfs (before eden/fs).
#
# The EdenFS Python CLI (edenfsctl.real) uses thrift-python ("python"
# generator, `*.thrift_types` modules) rather than the deprecated "py"
# generator upstream's CMake still wires up. Generate those modules here; the
# thrift-python runtime itself (`thrift.python`, `folly.iobuf`) comes from the
# Python environment that runs the CLI (see python-runtime.nix).
include(FBThriftPythonLibrary)

# Imported lazily (for reflection) by the generated code.
foreach(annotation thrift scope cpp rust)
  add_fbthrift_python_library(
    thrift_annotation_${annotation}_thrift_python
    thrift/annotation/${annotation}.thrift
    NAMESPACE facebook.thrift.annotation
  )
endforeach()

add_fbthrift_python_library(
  fb303_thrift_python
  fb303/thrift/fb303_core.thrift
  SERVICES
    BaseService
)

add_fbthrift_python_library(
  eden_config_thrift_python
  eden/fs/config/eden_config.thrift
  NAMESPACE eden.fs.config
  DEPENDS
    thrift_annotation_thrift_thrift_python
)

add_fbthrift_python_library(
  eden_service_thrift_python
  eden/fs/service/eden.thrift
  NAMESPACE eden.fs.service
  SERVICES
    EdenService
  DEPENDS
    eden_config_thrift_python
    fb303_thrift_python
    thrift_annotation_cpp_thrift_python
    thrift_annotation_rust_thrift_python
    thrift_annotation_scope_thrift_python
    thrift_annotation_thrift_thrift_python
)

add_fbthrift_python_library(
  eden_overlay_thrift_python
  eden/fs/inodes/overlay/overlay.thrift
  NAMESPACE facebook.eden
  DEPENDS
    thrift_annotation_thrift_thrift_python
)

# The CLI's other third-party Python dependencies (toml, filelock, psutil) also
# come from that Python environment instead of being bundled from wheels like
# getdeps does. Provide empty targets for them.
foreach(dep python-toml python-filelock python-psutil)
  add_library("${dep}::${dep}.py_lib" INTERFACE IMPORTED GLOBAL)
endforeach()
