{ lib, python3Packages }:

python3Packages.buildPythonPackage {
  pname = "uml-runner";
  version = "0.2.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./pyproject.toml ./uml_runner ];
  };

  pyproject = true;

  build-system = [ python3Packages.hatchling ];
  dependencies = [ python3Packages.rpyc ];

  pythonImportsCheck = [ "uml_runner" ];

  meta = {
    description = "Run NixOS systems under User-Mode Linux and drive them from Python";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "run-uml";
  };
}
