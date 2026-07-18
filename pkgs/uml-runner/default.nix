{ lib, python3Packages }:

python3Packages.buildPythonApplication {
  pname = "uml-runner";
  version = "0.1.0";

  src = ./.;

  pyproject = true;

  nativeBuildInputs = [ python3Packages.hatchling ];

  meta = with lib; {
    description = "Async UML kernel runner with TCP echo probe";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "uml-runner";
  };
}
