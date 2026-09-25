"""``python -m uml_runner.crun_launch``: see :func:`uml_runner.container.main`.

Its own module, because the package imports :mod:`uml_runner.container`
first, and runpy warns when the module it runs is already loaded.
"""

from .container import main

raise SystemExit(main())
