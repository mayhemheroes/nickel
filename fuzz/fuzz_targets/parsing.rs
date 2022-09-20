#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(mut program) = nickel_lang::program::Program::new_from_source(data, "fuzz") {
        _ = program.typecheck();
        _ = program.output_doc(&mut std::io::sink());
    }
});
