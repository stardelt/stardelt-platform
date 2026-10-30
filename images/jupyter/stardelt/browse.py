"""Catalog browser for stardelt notebooks.

Permission-aware listing via stardelt.sql() using SHOW/DESCRIBE/SELECT
under the person's token. Uses ipywidgets when available, otherwise
falls back to inline text output. jupyterlab-sidecar used if present.
"""
from __future__ import annotations

import html
import re
from typing import Any

import stardelt


MAX_LIST = 500


def _quote_ident(name: str) -> str:
    """Quote identifier with double quotes only when needed."""
    if name is None:
        raise ValueError("identifier required")
    s = str(name)
    # Quote if contains space, dash, quote, or other special chars
    if re.search(r'[^A-Za-z0-9_]', s) or (s and s[0].isdigit()):
        escaped = s.replace('"', '""')
        return f'"{escaped}"'
    # Also quote if it's a reserved word? be conservative
    if s.upper() in {
        'SELECT', 'FROM', 'WHERE', 'TABLE', 'SHOW', 'SCHEMA', 'CATALOG', 'ORDER', 'GROUP'
    }:
        escaped = s.replace('"', '""')
        return f'"{escaped}"'
    return s


class _Browser:
    def __init__(self):
        self._catalogs = []
        self._schemas = []
        self._tables = []
        self._columns = []
        self._current_catalog = None
        self._current_schema = None
        self._current_table = None
        self._catalogs_truncated = False
        self._schemas_truncated = False
        self._tables_truncated = False

    def _run_sql(self, query: str):
        return stardelt.sql(query)

    def load_catalogs(self):
        try:
            df = self._run_sql("SHOW CATALOGS")
        except Exception:
            raise
        rows = df.values.tolist() if hasattr(df, 'values') else []
        items = []
        for r in rows:
            name = str(r[0]) if len(r) > 0 else ""
            items.append(name)
        self._catalogs = items[:MAX_LIST]
        if len(items) > MAX_LIST:
            self._catalogs_truncated = True
        else:
            self._catalogs_truncated = False
        return self._catalogs

    def load_schemas(self, catalog: str):
        df = self._run_sql(f"SHOW SCHEMAS FROM {_quote_ident(catalog)}")
        rows = df.values.tolist() if hasattr(df, 'values') else []
        items = []
        for r in rows:
            name = str(r[0]) if len(r) > 0 else ""
            items.append(name)
        self._schemas = items[:MAX_LIST]
        if len(items) > MAX_LIST:
            self._schemas_truncated = True
        else:
            self._schemas_truncated = False
        self._current_catalog = catalog
        return self._schemas

    def load_tables(self, catalog: str, schema: str):
        df = self._run_sql(f"SHOW TABLES FROM {_quote_ident(catalog)}.{_quote_ident(schema)}")
        rows = df.values.tolist() if hasattr(df, 'values') else []
        items = []
        for r in rows:
            name = str(r[0]) if len(r) > 0 else ""
            items.append(name)
        self._tables = items[:MAX_LIST]
        if len(items) > MAX_LIST:
            self._tables_truncated = True
        else:
            self._tables_truncated = False
        self._current_catalog = catalog
        self._current_schema = schema
        return self._tables

    def load_columns(self, catalog: str, schema: str, table: str):
        self._current_catalog = catalog
        self._current_schema = schema
        self._current_table = table
        try:
            df = self._run_sql(f"DESCRIBE {_quote_ident(catalog)}.{_quote_ident(schema)}.{_quote_ident(table)}")
            rows = df.values.tolist() if hasattr(df, 'values') else []
            cols = []
            for r in rows:
                if len(r) == 0:
                    continue
                name = str(r[0])
                typ = str(r[1]) if len(r) > 1 else ""
                comment = str(r[2]) if len(r) > 2 else ""
                cols.append({"name": name, "type": typ, "comment": comment})
            self._columns = cols
            return self._columns
        except Exception:
            try:
                q = f"SELECT column_name, data_type, comment FROM {_quote_ident(catalog)}.information_schema.columns WHERE table_schema = '{schema}' AND table_name = '{table}'"
                df = self._run_sql(q)
                rows = df.values.tolist() if hasattr(df, 'values') else []
                cols = []
                for r in rows:
                    name = str(r[0]) if len(r) > 0 else ""
                    typ = str(r[1]) if len(r) > 1 else ""
                    comment = str(r[2]) if len(r) > 2 else ""
                    cols.append({"name": name, "type": typ, "comment": comment})
                self._columns = cols
                return self._columns
            except Exception:
                raise

    def preview(self, catalog: str, schema: str, table: str):
        try:
            df = self._run_sql(f"SELECT * FROM {_quote_ident(catalog)}.{_quote_ident(schema)}.{_quote_ident(table)} LIMIT 20")
            return df
        except Exception as e:
            raise

    def insert_select(self, catalog: str, schema: str, table: str):
        q = f"SELECT * FROM {_quote_ident(catalog)}.{_quote_ident(schema)}.{_quote_ident(table)} LIMIT 100"
        ip = None
        try:
            import builtins
            gip = getattr(builtins, 'get_ipython', None)
            if callable(gip):
                ip = gip()
        except Exception:
            ip = None
        if ip is None:
            try:
                from IPython import get_ipython
                ip = get_ipython()
            except Exception:
                ip = None
        if ip is not None:
            try:
                ip.set_next_input(q)
                return
            except Exception:
                pass
        print(q)
        return q

    def copy_name(self, catalog: str, schema: str, table: str):
        full = f"{_quote_ident(catalog)}.{_quote_ident(schema)}.{_quote_ident(table)}"
        try:
            import pyperclip
            pyperclip.copy(full)
        except Exception:
            pass
        return full


def _try_sidecar():
    try:
        from sidecar import Sidecar
        return Sidecar
    except Exception:
        try:
            import sidecar
            if hasattr(sidecar, 'Sidecar'):
                return sidecar.Sidecar
        except Exception:
            pass
    return None


def browse():
    """Open a catalog browser panel."""
    browser = _Browser()
    try:
        import ipywidgets as widgets
        from IPython.display import display
    except Exception as e:
        try:
            cats = browser.load_catalogs()
            print("Catalogs:")
            for c in cats:
                print(f"  {c}")
            if getattr(browser, '_catalogs_truncated', False):
                print(f"  N more: refine the filter")
            return
        except Exception as e2:
            print(str(e2))
            return

    Sidecar = _try_sidecar()
    filter_box = widgets.Text(description='Filter:', placeholder='filter...')
    catalogs_list = widgets.Select(options=[], rows=10)
    schemas_list = widgets.Select(options=[], rows=10)
    tables_list = widgets.Select(options=[], rows=10)
    columns_out = widgets.Output()
    preview_out = widgets.Output()
    insert_btn = widgets.Button(description='Insert SELECT')
    copy_btn = widgets.Button(description='Copy name')
    tab = widgets.Tab()
    tab.children = [columns_out, preview_out]
    tab.set_title(0, 'Columns')
    tab.set_title(1, 'Preview')

    def load_catalogs_ui():
        try:
            cats = browser.load_catalogs()
            filtered = [c for c in cats if (not filter_box.value or filter_box.value.lower() in str(c).lower())]
            options = list(filtered)
            if browser._catalogs_truncated and len(cats) >= MAX_LIST:
                options = options + ["N more: refine the filter"]
            catalogs_list.options = options
        except Exception as e:
            catalogs_list.options = [str(e)]

    def on_catalog_change(change):
        if change['type'] != 'change' or change['name'] != 'value':
            return
        val = change['new']
        if val == "N more: refine the filter":
            return
        try:
            schemas = browser.load_schemas(val)
            filtered = [s for s in schemas if (not filter_box.value or filter_box.value.lower() in str(s).lower())]
            options = list(filtered)
            if browser._schemas_truncated and len(schemas) >= MAX_LIST:
                options = options + ["N more: refine the filter"]
            schemas_list.options = options
            tables_list.options = []
        except Exception as e:
            schemas_list.options = [str(e)]

    def on_schema_change(change):
        if change['type'] != 'change' or change['name'] != 'value':
            return
        val = change['new']
        if val == "N more: refine the filter":
            return
        cat = catalogs_list.value
        try:
            tables = browser.load_tables(cat, val)
            filtered = [t for t in tables if (not filter_box.value or filter_box.value.lower() in str(t).lower())]
            options = list(filtered)
            if browser._tables_truncated and len(tables) >= MAX_LIST:
                options = options + ["N more: refine the filter"]
            tables_list.options = options
        except Exception as e:
            tables_list.options = [str(e)]

    def on_table_change(change):
        if change['type'] != 'change' or change['name'] != 'value':
            return
        val = change['new']
        if val == "N more: refine the filter":
            return
        cat = catalogs_list.value
        sch = schemas_list.value
        browser._current_catalog = cat
        browser._current_schema = sch
        browser._current_table = val
        with columns_out:
            columns_out.clear_output()
            try:
                cols = browser.load_columns(cat, sch, val)
                for c in cols:
                    name = str(c.get('name', ''))
                    typ = str(c.get('type', ''))
                    comment = str(c.get('comment', ''))
                    print(f"{name}	{typ}	{comment}")
            except Exception as e:
                print(str(e))

    def on_preview_click(change=None):
        cat = catalogs_list.value
        sch = schemas_list.value
        tbl = tables_list.value
        if not cat or not sch or not tbl or tbl == "N more: refine the filter":
            return
        with preview_out:
            preview_out.clear_output()
            try:
                df = browser.preview(cat, sch, tbl)
                from IPython.display import display
                display(df)
            except Exception as e:
                print(str(e))

    def on_insert_click(b):
        cat = catalogs_list.value
        sch = schemas_list.value
        tbl = tables_list.value
        if not cat or not sch or not tbl or tbl == "N more: refine the filter":
            return
        browser.insert_select(cat, sch, tbl)

    def on_copy_click(b):
        cat = catalogs_list.value
        sch = schemas_list.value
        tbl = tables_list.value
        if not cat or not sch or not tbl or tbl == "N more: refine the filter":
            return
        browser.copy_name(cat, sch, tbl)

    catalogs_list.observe(on_catalog_change)
    schemas_list.observe(on_schema_change)
    tables_list.observe(on_table_change)
    tab.observe(lambda c: on_preview_click() if c.get('name') == 'selected_index' and c.get('new') == 1 else None)
    insert_btn.on_click(on_insert_click)
    copy_btn.on_click(on_copy_click)

    load_catalogs_ui()

    left = widgets.VBox([widgets.Label('Catalogs'), catalogs_list])
    mid = widgets.VBox([widgets.Label('Schemas'), schemas_list])
    right = widgets.VBox([widgets.Label('Tables'), tables_list])
    lists = widgets.HBox([left, mid, right])
    buttons = widgets.HBox([insert_btn, copy_btn])
    panel = widgets.VBox([filter_box, lists, buttons, tab])

    if Sidecar is not None:
        try:
            sc = Sidecar(title='Catalog Browser')
            with sc:
                display(panel)
            return
        except Exception:
            pass

    display(panel)
    return


_Browser = _Browser
Browser = _Browser
browse = browse
__all__ = ["browse", "_Browser", "Browser"]
