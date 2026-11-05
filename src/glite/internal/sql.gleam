//// Scans SQL text the way SQLite's tokenizer does, enough to answer three
//// questions without preparing it:
////
//// - Is it exactly one statement? esqlite prepares only the first statement
////   and silently drops the rest, so more than one is refused.
//// - How many parameters does it take? SQLite binds missing parameters as
////   NULL, so a count mismatch is refused.
//// - Does it change rows (INSERT, UPDATE, DELETE, REPLACE), maybe (WITH), or
////   not at all? `sqlite3_changes` only counts the first kind.

import gleam/bit_array
import gleam/int
import gleam/set.{type Set}
import gleam/string
import glite/error.{type Error}

/// Whether a statement changes rows.
pub type Kind {
  /// INSERT, UPDATE, DELETE or REPLACE: `sqlite3_changes` counts its rows.
  Dml
  /// A statement starting with WITH, which may or may not change rows.
  With
  /// Anything else: changes no rows.
  Other
}

/// What a statement needs: how many parameters, and what kind it is.
pub type Analysis {
  Analysis(params: Int, kind: Kind)
}

type State {
  State(
    /// The statement's first three words, lowercase, most recent first.
    words: List(String),
    /// How many words are in `words`, up to 3.
    word_count: Int,
    /// Whether the statement has any token yet.
    started: Bool,
    /// CASE/BEGIN ... END nesting, so the semicolons inside a CREATE TRIGGER
    /// body don't end the statement.
    depth: Int,
    trigger: Bool,
    /// Whether the first statement has ended at a semicolon.
    ended: Bool,
    /// The highest parameter number so far.
    max: Int,
    /// Named parameters seen so far: a name used twice is one parameter.
    names: Set(BitArray),
  )
}

/// Check that `sql` is exactly one statement, and count its parameters.
pub fn analyze(sql: String) -> Result(Analysis, Error) {
  let state =
    State(
      words: [],
      word_count: 0,
      started: False,
      depth: 0,
      trigger: False,
      ended: False,
      max: 0,
      names: set.new(),
    )
  scan(<<sql:utf8>>, state)
}

fn scan(sql: BitArray, state: State) -> Result(Analysis, Error) {
  case sql, state {
    <<>>, State(started: False, ..) ->
      Error(error.InvalidSql("the SQL is empty"))
    <<>>, _ -> Ok(Analysis(params: state.max, kind: kind(state)))
    // Whitespace.
    <<c, rest:bits>>, _ if c == 32 || c == 9 || c == 10 || c == 13 || c == 12 ->
      scan(rest, state)
    // Comments.
    <<"--":utf8, rest:bits>>, _ -> scan(skip_past(rest, <<"\n":utf8>>), state)
    <<"/*":utf8, rest:bits>>, _ -> scan(skip_past(rest, <<"*/":utf8>>), state)
    // After the end of the first statement only whitespace, comments and
    // empty statements may follow; anything else is a second statement.
    <<";":utf8, rest:bits>>, State(ended: True, ..) -> scan(rest, state)
    _, State(ended: True, ..) ->
      Error(error.InvalidSql(
        "the SQL holds more than one statement; use exec_script for scripts",
      ))
    <<";":utf8, rest:bits>>, State(depth: 0, started: True, ..) ->
      scan(rest, State(..state, ended: True))
    <<";":utf8, rest:bits>>, _ -> scan(rest, state)
    // Quoted strings and identifiers.
    <<"'":utf8, rest:bits>>, _ -> scan(skip_quoted(rest, 39), token(state))
    <<"\"":utf8, rest:bits>>, _ -> scan(skip_quoted(rest, 34), token(state))
    <<"`":utf8, rest:bits>>, _ -> scan(skip_quoted(rest, 96), token(state))
    <<"[":utf8, rest:bits>>, _ ->
      scan(skip_past(rest, <<"]":utf8>>), token(state))
    // Parameters: ?, ?NNN, :name, @name and $name.
    <<"?":utf8, rest:bits>>, _ -> {
      let #(digits, rest) = take_while(rest, is_digit)
      let max = case digits {
        <<>> -> state.max + 1
        _ -> int.max(state.max, digits_to_int(digits, 0))
      }
      scan(rest, token(State(..state, max:)))
    }
    <<p, c, _:bits>>, _ if p == 58 || p == 64 || p == 36 -> {
      case is_ident_start(c) {
        False -> scan(drop(sql, 1), token(state))
        True -> {
          let #(name, rest) = take_while(drop(sql, 1), is_ident)
          let state = case set.contains(state.names, name) {
            True -> state
            False ->
              State(
                ..state,
                max: state.max + 1,
                names: set.insert(state.names, name),
              )
          }
          scan(rest, token(state))
        }
      }
    }
    // Numbers, including 1e10, 1e-5, 0x1F and 1_000.
    <<c, _:bits>>, _ if c >= 48 && c <= 57 -> {
      let #(_, rest) = take_while(sql, is_ident)
      scan(skip_exponent_sign(rest), token(state))
    }
    // Words: keywords and identifiers.
    <<c, _:bits>>, _ -> {
      case is_ident_start(c) {
        True -> {
          let #(word, rest) = take_while(sql, is_ident)
          scan(rest, add_word(state, word))
        }
        // Operators and punctuation.
        False -> scan(drop(sql, 1), token(state))
      }
    }
    // A partial byte can't happen in a String; treat it as punctuation.
    _, _ -> scan(<<>>, token(state))
  }
}

/// A token that isn't a word still makes the statement non-empty.
fn token(state: State) -> State {
  State(..state, started: True)
}

/// Track the statement's first words, and CASE/BEGIN ... END nesting.
fn add_word(state: State, word: BitArray) -> State {
  // Only the first three words and the nesting keywords matter, so only
  // short words are lowercased.
  let word = case bit_array.byte_size(word) <= 9 {
    True -> lowercase(word)
    False -> ""
  }
  let #(words, word_count) = case state.word_count < 3 {
    True -> #([word, ..state.words], state.word_count + 1)
    False -> #(state.words, state.word_count)
  }
  let trigger = state.trigger || is_create_trigger(words)
  let depth = case word {
    "case" -> state.depth + 1
    "begin" if trigger -> state.depth + 1
    "end" if state.depth > 0 -> state.depth - 1
    _ -> state.depth
  }
  State(..state, words:, word_count:, trigger:, depth:, started: True)
}

fn lowercase(word: BitArray) -> String {
  case bit_array.to_string(word) {
    Ok(text) -> string.lowercase(text)
    // A String's bytes are always valid UTF-8, and a word is cut at ASCII
    // bytes only, so this can't happen.
    Error(Nil) -> panic as "glite: a SQL word was not valid UTF-8"
  }
}

/// `words` is most recent first.
fn is_create_trigger(words: List(String)) -> Bool {
  case words {
    ["trigger", "create"] -> True
    ["trigger", "temp", "create"] -> True
    ["trigger", "temporary", "create"] -> True
    [_, "trigger", "create"] -> True
    _ -> False
  }
}

fn kind(state: State) -> Kind {
  case first_word(state.words) {
    "insert" | "update" | "delete" | "replace" -> Dml
    "with" -> With
    _ -> Other
  }
}

fn first_word(words: List(String)) -> String {
  case words {
    [] -> ""
    [word] -> word
    [_, ..rest] -> first_word(rest)
  }
}

fn is_digit(c: Int) -> Bool {
  c >= 48 && c <= 57
}

fn is_ident_start(c: Int) -> Bool {
  c >= 97 && c <= 122 || c >= 65 && c <= 90 || c == 95 || c >= 128
}

fn is_ident(c: Int) -> Bool {
  is_ident_start(c) || is_digit(c) || c == 36
}

fn digits_to_int(digits: BitArray, acc: Int) -> Int {
  case digits {
    <<d, rest:bits>> -> digits_to_int(rest, acc * 10 + d - 48)
    _ -> acc
  }
}

/// Split `sql` after its longest prefix of bytes that satisfy `keep`.
fn take_while(sql: BitArray, keep: fn(Int) -> Bool) -> #(BitArray, BitArray) {
  let n = count_while(sql, keep, 0)
  #(slice(sql, 0, n), drop(sql, n))
}

fn count_while(sql: BitArray, keep: fn(Int) -> Bool, n: Int) -> Int {
  case sql {
    <<c, rest:bits>> ->
      case keep(c) {
        True -> count_while(rest, keep, n + 1)
        False -> n
      }
    _ -> n
  }
}

/// The sign in an exponent, as in 1e-5, belongs to the number.
fn skip_exponent_sign(sql: BitArray) -> BitArray {
  case sql {
    <<s, c, _:bits>> if s == 43 || s == 45 ->
      case is_digit(c) {
        True -> take_while(drop(sql, 1), is_ident).1
        False -> sql
      }
    _ -> sql
  }
}

/// Skip to after the closing quote; a doubled quote is an escaped quote.
fn skip_quoted(sql: BitArray, quote: Int) -> BitArray {
  let rest = skip_past(sql, <<quote>>)
  case rest {
    <<c, after:bits>> if c == quote -> skip_quoted(after, quote)
    _ -> rest
  }
}

/// Skip to just after the first `marker`, or to the end if there is none.
fn skip_past(sql: BitArray, marker: BitArray) -> BitArray {
  let size = bit_array.byte_size(marker)
  case sql {
    <<>> -> <<>>
    _ ->
      case bit_array.slice(sql, 0, size) {
        Ok(prefix) if prefix == marker -> drop(sql, size)
        _ -> skip_past(drop(sql, 1), marker)
      }
  }
}

fn slice(sql: BitArray, from: Int, length: Int) -> BitArray {
  case bit_array.slice(sql, from, length) {
    Ok(part) -> part
    // Callers only slice within what they've already scanned.
    Error(Nil) -> panic as "glite: SQL slice out of range"
  }
}

fn drop(sql: BitArray, n: Int) -> BitArray {
  slice(sql, n, bit_array.byte_size(sql) - n)
}
