"""Exercise the real Store SQL against SQLite, including existing user records."""
import sqlite3
import unittest

from run_lua_specs import runtime


class ChapterHistoryTests(unittest.TestCase):
    def test_existing_history_migrates_and_saves_any_chapter(self):
        lua = runtime()
        db = sqlite3.connect(':memory:')
        self.addCleanup(db.close)
        db.executescript('''CREATE TABLE history(site_id TEXT,comic_id TEXT,title TEXT,
            author TEXT,cover_url TEXT,detail_url TEXT,page_index INTEGER,
            total_pages INTEGER,last_read_at INTEGER,PRIMARY KEY(site_id,comic_id));
            INSERT INTO history VALUES('zero','old','Old','','','',7,20,1);''')

        def execute(_, sql, args=None):
            if args is not None and len(args):
                db.execute(sql, [args[i] for i in range(1, len(args)+1)])
            else:
                db.executescript(sql)
            return True

        def query(_, sql, args=None):
            values = [args[i] for i in range(1, len(args)+1)] if args else []
            return lua.table_from([lua.table_from(row) for row in db.execute(sql, values)])

        database = lua.table_from({'exec': execute, 'query': query})
        store = lua.eval("function(options) return require('mangaweb.store'):new(options) end")(lua.table_from({'database': database}))
        old = store.get_history(store, 'zero', 'old')
        self.assertEqual(old.page_index, 7)
        self.assertEqual(old.chapter_id, '')
        record = lua.table_from(dict(site_id='zero', comic_id='a', title='Comic',
            chapter_id='c2', chapter_title='第二话', page_index=13, total_pages=30))
        self.assertTrue(store.save_history(store, record))
        saved = store.get_history(store, 'zero', 'a')
        self.assertEqual((saved.chapter_id, saved.chapter_title, saved.page_index), ('c2', '第二话', 13))
        self.assertEqual(store.list_history(store, 'zero')[1].chapter_id, 'c2')
        # Opening a second Store does not attempt to add columns twice.
        lua.eval("function(options) return require('mangaweb.store'):new(options) end")(lua.table_from({'database': database}))
