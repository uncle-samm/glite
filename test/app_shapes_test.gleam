//// The statement shapes a real app's store uses for grants, projects and the
//// push queue, checked end to end.

import gleam/option.{Some}
import glite
import glite/config
import glite/decode
import glite/error
import glite/tx

const schema =
  "
CREATE TABLE projects (
  name TEXT PRIMARY KEY,
  bare_repo_path TEXT NOT NULL UNIQUE,
  upstream TEXT NOT NULL,
  delivery_rule TEXT NOT NULL CHECK (delivery_rule IN ('push', 'pr', 'integrate'))
);
CREATE TABLE grants (
  agent TEXT NOT NULL,
  kind TEXT NOT NULL,
  scope TEXT NOT NULL,
  permission TEXT NOT NULL,
  created INTEGER NOT NULL,
  PRIMARY KEY (agent, kind, scope)
);
CREATE TABLE queue (
  id INTEGER PRIMARY KEY,
  project TEXT NOT NULL REFERENCES projects (name),
  branch TEXT NOT NULL,
  agent TEXT NOT NULL,
  purpose TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'waiting',
  batch INTEGER,
  UNIQUE (project, branch)
);
"

fn store() -> glite.Connection {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) = glite.exec_script(conn, schema)
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO projects VALUES (?, ?, ?, ?)", [
      glite.text("app"),
      glite.text("/var/lib/app/git/app.git"),
      glite.text("github:example/app"),
      glite.text("integrate"),
    ])
  conn
}

pub fn replace_an_agents_grants_atomically_test() {
  let conn = store()
  let put = fn(grants: List(#(String, String, String))) {
    glite.transaction(conn, glite.Immediate, fn(t) {
      case
        tx.exec(t, "DELETE FROM grants WHERE agent = ?", [glite.text("a1")])
      {
        Error(e) -> Error(e)
        Ok(_) ->
          tx.exec_many(
            t,
            "INSERT INTO grants (agent, kind, scope, permission, created) VALUES ('a1', ?, ?, ?, unixepoch())",
            grant_params(grants),
          )
      }
    })
  }
  let assert Ok(2) =
    put([
      #("github", "example/app", "write"),
      #("git", "app", "push"),
    ])
  // A duplicate grant fails the whole replacement, keeping the old grants.
  let assert Error(glite.RolledBack(error.Constraint(error.PrimaryKey, _))) =
    put([#("git", "app", "push"), #("git", "app", "read")])
  let assert Ok(["git app push", "github example/app write"]) =
    glite.query(
      conn,
      "SELECT kind || ' ' || scope || ' ' || permission FROM grants WHERE agent = ? ORDER BY kind",
      [glite.text("a1")],
      {
        use s <- decode.element(0, decode.text)
        decode.success(s)
      },
    )
}

fn grant_params(
  grants: List(#(String, String, String)),
) -> List(List(glite.Param)) {
  case grants {
    [] -> []
    [#(kind, scope, permission), ..rest] -> [
      [glite.text(kind), glite.text(scope), glite.text(permission)],
      ..grant_params(rest)
    ]
  }
}

pub fn queue_claims_a_batch_and_moves_state_once_test() {
  let conn = store()
  let assert Ok(2) =
    glite.exec_many(
      conn,
      "INSERT INTO queue (project, branch, agent, purpose) VALUES ('app', ?, ?, ?)",
      [
        [glite.text("feat/a"), glite.text("a1"), glite.text("add a")],
        [glite.text("feat/b"), glite.text("a2"), glite.text("add b")],
      ],
    )
  // An unknown project is refused by the foreign key.
  let assert Error(error.Constraint(error.ForeignKey, _)) =
    glite.exec(
      conn,
      "INSERT INTO queue (project, branch, agent, purpose) VALUES ('nope', 'x', 'a1', 'x')",
      [],
    )
  // Put every waiting branch into batch 1 and get the claimed rows back.
  let assert Ok(["feat/a", "feat/b"]) =
    glite.query(
      conn,
      "UPDATE queue SET state = 'batched', batch = ? WHERE project = ? AND state = 'waiting' RETURNING branch",
      [glite.int(1), glite.text("app")],
      {
        use s <- decode.element(0, decode.text)
        decode.success(s)
      },
    )
  // A state change only applies from the expected state: the second try
  // changes nothing.
  let move = fn() {
    glite.exec(
      conn,
      "UPDATE queue SET state = 'merged' WHERE batch = ? AND state = 'batched'",
      [glite.int(1)],
    )
  }
  let assert Ok(2) = move()
  let assert Ok(0) = move()
  let assert Ok([#("feat/a", Some(1)), #("feat/b", Some(1))]) =
    glite.query(conn, "SELECT branch, batch FROM queue ORDER BY branch", [], {
      use branch <- decode.element(0, decode.text)
      use batch <- decode.element(1, decode.optional(decode.int))
      decode.success(#(branch, batch))
    })
}
