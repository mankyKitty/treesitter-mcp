use serde_json::json;
use std::fs;
use tempfile::tempdir;
use treesitter_mcp::analysis::dependencies::resolve_dependencies;
use treesitter_mcp::analysis::shape::extract_enhanced_shape;
use treesitter_mcp::parser::{parse_code, Language};

mod common;

const SRC: &str = r#"module My.Module (foo, Bar(..)) where

import Data.List (sort)
import qualified Data.Map as Map

-- | A data type for shapes.
data Shape = Circle Double | Rect Double Double
  deriving (Show, Eq)

newtype Wrapper a = Wrapper { unwrap :: a }

type Name = String

class Greet a where
  greet :: a -> String

instance Greet Shape where
  greet _ = "shape"

-- | Compute the area.
area :: Shape -> Double
area (Circle r) = pi * r * r
area (Rect w h) = w * h

foo :: Int -> Int
foo x = bar (x + 1)
"#;

#[test]
fn haskell_enhanced_shape_extracts_symbols() {
    let tree = parse_code(SRC, Language::Haskell).expect("parse haskell");
    let shape = extract_enhanced_shape(&tree, SRC, Language::Haskell, Some("My/Module.hs"), true)
        .expect("extract haskell shape");

    // Imports
    assert_eq!(shape.imports.len(), 2, "expected two imports");

    // Structs: data_type, newtype, type_synomym
    let struct_names: Vec<&str> = shape.structs.iter().map(|s| s.name.as_str()).collect();
    assert!(struct_names.contains(&"Shape"));
    assert!(struct_names.contains(&"Wrapper"));
    assert!(struct_names.contains(&"Name"));

    // data type carries its Haddock doc
    let shape_ty = shape.structs.iter().find(|s| s.name == "Shape").unwrap();
    assert_eq!(shape_ty.doc.as_deref(), Some("A data type for shapes."));

    // Traits: type classes
    assert!(shape.traits.iter().any(|t| t.name == "Greet"));

    // Functions: area + foo, deduplicated across clauses, with type signatures.
    let area = shape
        .functions
        .iter()
        .find(|f| f.name == "area")
        .expect("area function present");
    assert_eq!(
        shape.functions.iter().filter(|f| f.name == "area").count(),
        1,
        "area clauses should be merged into one entry"
    );
    assert_eq!(area.signature, "area :: Shape -> Double");
    assert_eq!(area.doc.as_deref(), Some("Compute the area."));

    let foo = shape.functions.iter().find(|f| f.name == "foo").unwrap();
    assert_eq!(foo.signature, "foo :: Int -> Int");
}

const CALL_GRAPH_SRC: &str = r#"module Lib (helper, runAll, process) where

import Data.List (sort)

helper :: [Int] -> [Int]
helper xs = sort xs

process :: [Int] -> [Int]
process xs = map negate xs

runAll :: [Int] -> [Int]
runAll xs = helper (process xs)
"#;

#[test]
fn haskell_call_graph_resolves_curried_callees_and_callers() {
    let dir = tempdir().unwrap();
    let file_path = dir.path().join("Lib.hs");
    fs::write(&file_path, CALL_GRAPH_SRC).unwrap();

    // Callees of `runAll`: both `helper` and `process` are resolved despite the
    // curried `helper (process xs)` application spine.
    let result = treesitter_mcp::analysis::call_graph::execute(&json!({
        "file_path": file_path.to_str().unwrap(),
        "symbol_name": "runAll",
        "direction": "callees",
        "depth": 1,
        "max_tokens": 4000,
    }))
    .unwrap();
    let output: serde_json::Value =
        serde_json::from_str(&common::get_result_text(&result)).unwrap();
    let rows = common::helpers::parse_compact_rows(output["edges"].as_str().unwrap());
    // Columns: direction|symbol|file|line|scope|depth
    let callees: Vec<&str> = rows
        .iter()
        .filter(|r| r.first().map(String::as_str) == Some("callee"))
        .filter_map(|r| r.get(1).map(String::as_str))
        .collect();
    assert!(callees.contains(&"helper"), "callees were {callees:?}");
    assert!(callees.contains(&"process"), "callees were {callees:?}");

    // Callers of `helper`: `runAll` calls it.
    let result = treesitter_mcp::analysis::call_graph::execute(&json!({
        "file_path": file_path.to_str().unwrap(),
        "symbol_name": "helper",
        "direction": "callers",
        "depth": 1,
        "max_tokens": 4000,
    }))
    .unwrap();
    let output: serde_json::Value =
        serde_json::from_str(&common::get_result_text(&result)).unwrap();
    let rows = common::helpers::parse_compact_rows(output["edges"].as_str().unwrap());
    let callers: Vec<&str> = rows
        .iter()
        .filter(|r| r.first().map(String::as_str) == Some("caller"))
        .filter_map(|r| r.get(1).map(String::as_str))
        .collect();
    assert!(callers.contains(&"runAll"), "callers were {callers:?}");
}

#[test]
fn haskell_dependencies_resolve_module_imports() {
    let dir = tempdir().unwrap();
    let src = dir.path().join("src");
    fs::create_dir_all(src.join("My")).unwrap();

    let util = src.join("My").join("Util.hs");
    fs::write(&util, "module My.Util (helper) where\n\nhelper :: Int -> Int\nhelper = (+1)\n")
        .unwrap();
    fs::write(
        src.join("My").join("Data.hs"),
        "module My.Data where\n\nx :: Int\nx = 1\n",
    )
    .unwrap();

    let main = src.join("Main.hs");
    let main_src = "module Main where\n\n\
        import My.Util (helper)\n\
        import qualified My.Data as D\n\
        import Data.List (sort)\n\n\
        main :: IO ()\n\
        main = print (helper 1)\n";
    fs::write(&main, main_src).unwrap();

    let deps = resolve_dependencies(Language::Haskell, main_src, &main, dir.path());

    // Both project-local modules resolve (qualified import included); the
    // external `Data.List` and the alias `D` do not produce spurious entries.
    assert!(deps.iter().any(|p| p.ends_with("My/Util.hs")), "deps: {deps:?}");
    assert!(deps.iter().any(|p| p.ends_with("My/Data.hs")), "deps: {deps:?}");
    assert_eq!(deps.len(), 2, "expected exactly two local deps, got {deps:?}");
}
