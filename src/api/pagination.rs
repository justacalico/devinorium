//! Pagination helpers for list endpoints.
//!
//! Endpoints accept `?limit=&offset=` and, when the client omits them, fall
//! back to returning the full list so existing callers keep working.

use serde::Deserialize;

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub struct Pagination {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

impl Pagination {
    /// Maximum page size for safety.
    pub const MAX_LIMIT: i64 = 200;

    /// Return validated `(limit, offset)` values.
    ///
    /// - If `limit` is absent, the result is `None`, which callers should
    ///   interpret as "return everything".
    /// - If `offset` is absent, it defaults to `0`.
    pub fn bounds(&self) -> (Option<i64>, i64) {
        let limit = self
            .limit
            .filter(|&l| l > 0)
            .map(|l| l.min(Self::MAX_LIMIT));
        let offset = self.offset.unwrap_or(0).max(0);
        (limit, offset)
    }

    /// Append `LIMIT ... OFFSET ...` to a SQL string when a limit is present.
    pub fn apply_to_sql(&self, sql: &mut String) {
        let (limit, offset) = self.bounds();
        if let Some(l) = limit {
            sql.push_str(&format!(" LIMIT {l} OFFSET {offset}"));
        }
    }

    /// Convert pagination to `(limit, offset)` for in-memory slicing.
    pub fn to_slice(&self) -> (Option<usize>, usize) {
        let (limit, offset) = self.bounds();
        (
            limit.map(|l| l as usize),
            std::cmp::min(offset, i64::MAX) as usize,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_return_everything() {
        let p = Pagination::default();
        assert_eq!(p.bounds(), (None, 0));
    }

    #[test]
    fn clamps_negative_limit_to_none() {
        let p = Pagination {
            limit: Some(-5),
            offset: Some(0),
        };
        assert_eq!(p.bounds(), (None, 0));
    }

    #[test]
    fn clamps_negative_offset_to_zero() {
        let p = Pagination {
            limit: Some(10),
            offset: Some(-3),
        };
        assert_eq!(p.bounds(), (Some(10), 0));
    }

    #[test]
    fn clamps_oversized_limit_to_max() {
        let p = Pagination {
            limit: Some(5000),
            offset: Some(100),
        };
        assert_eq!(p.bounds(), (Some(Pagination::MAX_LIMIT), 100));
    }

    #[test]
    fn sql_appends_limit_and_offset() {
        let p = Pagination {
            limit: Some(25),
            offset: Some(50),
        };
        let mut sql = "SELECT * FROM t".to_string();
        p.apply_to_sql(&mut sql);
        assert_eq!(sql, "SELECT * FROM t LIMIT 25 OFFSET 50");
    }

    #[test]
    fn sql_appends_nothing_when_unlimited() {
        let p = Pagination::default();
        let mut sql = "SELECT * FROM t".to_string();
        p.apply_to_sql(&mut sql);
        assert_eq!(sql, "SELECT * FROM t");
    }
}
