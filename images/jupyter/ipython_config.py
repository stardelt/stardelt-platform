"""System IPython config of the notebook image: every kernel loads the stardelt SQL magic,
so `%sql select 1` works in the first cell (stardelt-python: stardelt/sqlmagic.py)."""

c = get_config()  # noqa: F821  (IPython provides it)
c.InteractiveShellApp.extensions = ["stardelt.sqlmagic"]
