use thiserror::Error;

pub const MAX_CHUNK: usize = 64 * 1024;
pub const MAX_INPUT: usize = 64 * 1024;
pub const MAX_COLUMNS: u16 = 500;
pub const MAX_ROWS: u16 = 500;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Error)]
pub enum Error {
    #[error("invalid terminal dimensions")]
    Dimensions,
    #[error("terminal payload exceeds bounds")]
    Bounds,
    #[error("terminal generation is stale")]
    StaleGeneration,
    #[error("terminal is closed")]
    Closed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Dimensions {
    pub columns: u16,
    pub rows: u16,
}
impl Dimensions {
    pub fn new(columns: u16, rows: u16) -> Result<Self, Error> {
        if columns == 0 || rows == 0 || columns > MAX_COLUMNS || rows > MAX_ROWS {
            return Err(Error::Dimensions);
        }
        Ok(Self { columns, rows })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum State {
    Detached,
    Attached,
    Closed,
}

#[derive(Debug)]
pub struct Session {
    generation: u64,
    dimensions: Dimensions,
    state: State,
}
impl Session {
    pub fn attach(generation: u64, dimensions: Dimensions) -> Self {
        Self {
            generation,
            dimensions,
            state: State::Attached,
        }
    }
    pub fn state(&self) -> State {
        self.state
    }
    pub fn dimensions(&self) -> Dimensions {
        self.dimensions
    }
    pub fn accept_output(&self, generation: u64, chunk: &[u8]) -> Result<(), Error> {
        self.check(generation)?;
        if chunk.len() > MAX_CHUNK {
            return Err(Error::Bounds);
        }
        Ok(())
    }
    pub fn input(&self, generation: u64, bytes: &[u8]) -> Result<(), Error> {
        self.check(generation)?;
        if bytes.len() > MAX_INPUT {
            return Err(Error::Bounds);
        }
        Ok(())
    }
    pub fn resize(&mut self, generation: u64, dimensions: Dimensions) -> Result<(), Error> {
        self.check(generation)?;
        self.dimensions = dimensions;
        Ok(())
    }
    pub fn close(&mut self, generation: u64) -> Result<(), Error> {
        self.check(generation)?;
        self.state = State::Closed;
        Ok(())
    }
    fn check(&self, generation: u64) -> Result<(), Error> {
        if generation != self.generation {
            return Err(Error::StaleGeneration);
        }
        if self.state == State::Closed {
            return Err(Error::Closed);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_and_closed_sessions_refuse_all_controls() {
        let d = Dimensions::new(80, 24).unwrap();
        let mut s = Session::attach(7, d);
        assert_eq!(s.accept_output(6, b"x"), Err(Error::StaleGeneration));
        assert!(s.input(7, b"x").is_ok());
        s.close(7).unwrap();
        assert_eq!(s.input(7, b"x"), Err(Error::Closed));
    }
    #[test]
    fn bounds_are_fail_closed() {
        assert_eq!(Dimensions::new(0, 24), Err(Error::Dimensions));
        let s = Session::attach(1, Dimensions::new(80, 24).unwrap());
        assert_eq!(
            s.accept_output(1, &vec![0; MAX_CHUNK + 1]),
            Err(Error::Bounds)
        );
        assert_eq!(s.input(1, &vec![0; MAX_INPUT + 1]), Err(Error::Bounds));
    }
}
