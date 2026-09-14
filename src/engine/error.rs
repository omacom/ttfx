//! Engine error taxonomy. Error *conditions* match upstream; message text may differ.

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineError {
    /// UnsupportedAnsiSequenceError: printed to stderr, exit 1 (see __main__.py).
    UnsupportedAnsiSequence(String),
    /// Any other upstream hard error (ValueError etc.).
    Other(String),
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            // Debug of the sequence pulled unicode/printable into every wasm.
            // The CLI still prints `{seq:?}` itself; Session only needs the tag.
            EngineError::UnsupportedAnsiSequence(_) => {
                f.write_str("Unsupported ANSI sequence in input data")
            }
            EngineError::Other(msg) => f.write_str(msg),
        }
    }
}

impl std::error::Error for EngineError {}
