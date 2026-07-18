{ lib, python3Packages }:

python3Packages.buildPythonApplication {
  pname = "uml-runner";
  version = "0.1.0";

  src = ./.;

  pyproject = true;

  nativeBuildInputs = [ python3Packages.hatchling ];
  propagatedBuildInputs = [ python3Packages.asyncssh ];

  meta = with lib; {
    description = "Async UML kernel runner with SSH probe";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "uml-runner";
  };
}
