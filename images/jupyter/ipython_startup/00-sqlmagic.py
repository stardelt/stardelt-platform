"""IPython startup: register JupySQL integration."""
try:
    import stardelt.sqlmagic  # noqa: F401
except Exception:
    pass
