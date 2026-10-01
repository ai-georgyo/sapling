# Python runtime for the EdenFS CLI (`edenfsctl.real`).
#
# The Python CLI uses thrift-python (`thrift.python.*`, Cython extensions on
# top of the C++ Thrift runtime) and folly's Python bindings (`folly.iobuf`).
# nixpkgs builds neither, so build them here from the same folly/fbthrift
# as the rest of the stack (this is part of the fb-stack.nix scope), as
# separate derivations so that the EdenFS daemon itself does not depend on
# Python.
{
  lib,
  python3,
  patchelf,
  autoPatchelfHook,
  runCommand,
  writeTextDir,
  libaio,
  libevent,
  libiberty,
  libsodium,
  libunwind,
  snappy,
  xz,
  folly,
  fbthrift,
}:

let
  pythonForBuild = python3.withPackages (ps: [
    ps.cython
    ps.pip
    ps.setuptools
    ps.wheel
  ]);

  sitePackages = python3.sitePackages;

  # Extension modules are linked with plain `-L<build dir>` flags, so make
  # them find the libraries they were linked against once installed.
  fixExtensionRpaths = output: libDirs: ''
    find ${output}/${sitePackages} -name '*.so' -print0 | while IFS= read -r -d "" so; do
      patchelf --add-rpath ${lib.concatStringsSep ":" libDirs} "$so"
    done
  '';

  # folly with its Python bindings (`folly.iobuf`, `folly.executor`). The
  # Python package goes to `dev`, next to the headers and .pxd files that
  # thrift-python's build looks for relative to folly's CMake package.
  # This is a second build of the same folly sources and configuration as
  # `folly` (plus the Python parts, which live in libfolly_python_cpp and
  # `dev`), so its libfolly is interchangeable with `folly`'s (both
  # get loaded into the Python CLI, through thrift-python and fizz/wangle).
  folly-python = folly.overrideAttrs (old: {
    pname = "folly-python";
    nativeBuildInputs = old.nativeBuildInputs ++ [
      pythonForBuild
      patchelf
    ];
    buildInputs = old.buildInputs ++ [ python3 ];
    cmakeFlags = old.cmakeFlags ++ [
      (lib.cmakeBool "PYTHON_EXTENSIONS" true)
      (lib.cmakeFeature "PYTHON_PACKAGE_INSTALL_DIR" (placeholder "dev"))
    ];
    env = (old.env or { }) // {
      # The Cython extensions are built by setup.py, which does not get the
      # compile definitions CMake's imported glog target would add.
      NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "") + " -DGLOG_USE_GLOG_EXPORT";
      # setup.py builds a wheel which is then installed with pip.
      PIP_NO_INDEX = "1";
      PIP_DISABLE_PIP_VERSION_CHECK = "1";
    };
    postFixup =
      (old.postFixup or "")
      + fixExtensionRpaths "$dev" [ "${placeholder "out"}/lib" ]
      + ''
        # libfolly_python_cpp links libpython from the Python CMake found,
        # which is the build tooling env (Cython, pip, ...); point its
        # RUNPATH at the plain interpreter so that env is not kept at runtime.
        for so in $out/lib/libfolly_python_cpp.so*; do
          [ -L "$so" ] && continue
          rpath=$(patchelf --print-rpath "$so" | sed 's|${pythonForBuild}/lib|${python3}/lib|g')
          patchelf --set-rpath "$rpath" "$so"
        done
      '';
    disallowedReferences = [ pythonForBuild ];
  });

  # thrift-python's CMake links `libevent::core`/`libevent::extra`, which
  # nixpkgs' (autotools-built) libevent does not export.
  libeventCmakeConfig = writeTextDir "lib/cmake/Libevent/LibeventConfig.cmake" ''
    foreach(_c core extra)
      if(NOT TARGET libevent::''${_c})
        add_library(libevent::''${_c} SHARED IMPORTED)
        set_target_properties(libevent::''${_c} PROPERTIES
          IMPORTED_LOCATION "${lib.getLib libevent}/lib/libevent_''${_c}.so"
          INTERFACE_INCLUDE_DIRECTORIES "${lib.getDev libevent}/include")
      endif()
    endforeach()
    set(Libevent_FOUND TRUE)
  '';

  fbthrift-python = (fbthrift.override { folly = folly-python; }).overrideAttrs (old: {
    pname = "fbthrift-python";
    # `python` holds the thrift-python package (which also bundles folly's
    # Python bindings): thrift.python, thrift.py3, apache.thrift.metadata, folly.
    outputs = old.outputs ++ [ "python" ];
    nativeBuildInputs = old.nativeBuildInputs ++ [
      pythonForBuild
      autoPatchelfHook
    ];
    buildInputs = old.buildInputs ++ [
      python3
      libiberty
      libeventCmakeConfig
      # Linked into every extension module by thrift/lib/setup.py.
      libaio
      libsodium
      libunwind
      snappy
      xz
    ];
    cmakeFlags = old.cmakeFlags ++ [
      (lib.cmakeBool "THRIFT_PYTHON" true)
      (lib.cmakeFeature "PYTHON_PACKAGE_INSTALL_DIR" "${placeholder "out"}/lib")
    ];
    postPatch = (old.postPatch or "") + ''
      # Install the (non-"repaired") wheel into $out instead of bundling all
      # shared libraries into it with auditwheel.
      substituteInPlace thrift/lib/python/CMakeLists.txt \
        --replace-fail \
          '-m auditwheel repair --wheel-dir' \
          '-c "import sys" --wheel-dir' \
        --replace-fail \
          'DIRECTORY "''${_cybld}/dist_self_contained/"' \
          'DIRECTORY "''${_cybld}/dist/"'
      # The test suite (which also pip-installs extra test dependencies from
      # the network) is not run.
      substituteInPlace thrift/lib/python/CMakeLists.txt \
        --replace-fail \
          'add_subdirectory(test)' \
          'add_custom_target(create_binding_symlink_lib_test)'
      cat >> thrift/lib/python/CMakeLists.txt <<'CMAKE'
      install(CODE "
        file(GLOB _whl \"''${_cybld}/dist/*.whl\")
        execute_process(
          COMMAND ''${Python3_EXECUTABLE} -m pip install \''${_whl}
            --prefix ''${CMAKE_INSTALL_PREFIX} --no-deps --no-index
          COMMAND_ERROR_IS_FATAL ANY)
      ")
      CMAKE
    '';
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "") + " -DGLOG_USE_GLOG_EXPORT";
      PIP_DISABLE_PIP_VERSION_CHECK = "1";
    };
    postInstall = (old.postInstall or "") + ''
      mkdir -p $python/lib
      mv $out/lib/${python3.libPrefix} $python/lib/
      rm -rf $out/lib/libthrift_python_cpp.so* $out/share/thrift/wheels
    '';
  });

  # The thrift-python runtime as a Python package, for python3.withPackages.
  # A copy rather than `fbthrift-python.python` itself: buildEnv would link
  # the derivation's default output, and the bytecode pip compiled refers to
  # the original install location in `out`.
  thrift-python = python3.pkgs.toPythonModule (
    runCommand "thrift-python-${fbthrift-python.version}" { nativeBuildInputs = [ python3 ]; } ''
      mkdir -p $out/${sitePackages}
      cp -r ${fbthrift-python.python}/${sitePackages}/. $out/${sitePackages}/
      chmod -R u+w $out
      find $out -name __pycache__ -type d -prune -exec rm -r {} +
      python3 -m compileall -q $out/${sitePackages}
    ''
  );
in
{
  inherit folly-python fbthrift-python thrift-python;
}
