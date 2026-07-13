//! Port of the original fork's `parsing` harness (fuzz/fuzz_targets/parsing.rs):
//! parse an arbitrary byte buffer as a Nickel program, then walk-typecheck it and
//! extract/serialize its documentation.
#![no_main]
use libfuzzer_sys::fuzz_target;

use std::io::Cursor;

use nickel_lang_core::{
    eval::cache::CacheImpl,
    program::{Program, ProgramBuilder},
    typecheck::TypecheckMode,
};

fuzz_target!(|data: &[u8]| {
    let result: Result<Program<CacheImpl>, _> = ProgramBuilder::new()
        .add_source(Cursor::new(data.to_vec()), "fuzz")
        .build();

    if let Ok(mut program) = result {
        let _ = program.typecheck(TypecheckMode::Walk);
        if let Ok(doc) = program.extract_doc() {
            let _ = doc.write_markdown(&mut std::io::sink());
        }
    }
});
