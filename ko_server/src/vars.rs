use std::collections::BTreeMap;
use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::ids::VarName;

const MAX_VALUE: usize = (1 << 20) - 4096;
const MAX_TOTAL: usize = 8 << 20;
const MAX_NAMES: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    ValueTooLarge,
    TotalTooLarge,
    TooManyNames,
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Refusal::ValueTooLarge => "variable too large",
            Refusal::TotalTooLarge => "variables too large",
            Refusal::TooManyNames => "too many variables",
        })
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    try_from = "BTreeMap<VarName, Value>",
    into = "BTreeMap<VarName, Value>"
)]
pub struct Vars {
    map: BTreeMap<VarName, (Value, usize)>,
    bytes: usize,
}

pub type Loose = BTreeMap<String, Value>;

impl TryFrom<BTreeMap<VarName, Value>> for Vars {
    type Error = Refusal;

    fn try_from(map: BTreeMap<VarName, Value>) -> Result<Vars, Refusal> {
        let mut vars = Vars::default();
        for (name, value) in map {
            vars.set(&name, value)?;
        }
        Ok(vars)
    }
}

impl From<Vars> for BTreeMap<VarName, Value> {
    fn from(vars: Vars) -> BTreeMap<VarName, Value> {
        vars.map
            .into_iter()
            .map(|(name, (value, _))| (name, value))
            .collect()
    }
}

impl Vars {
    pub(crate) fn checked(loose: Loose) -> Result<Vars, String> {
        let mut map = BTreeMap::new();
        for (name, value) in loose {
            map.insert(
                VarName::new(&name).map_err(|invalid| invalid.to_string())?,
                value,
            );
        }
        Vars::try_from(map).map_err(|refusal| refusal.to_string())
    }

    pub(crate) fn loose(&self) -> Loose {
        self.map
            .iter()
            .map(|(name, (value, _))| (name.as_str().to_owned(), value.clone()))
            .collect()
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    pub(crate) fn all(&self) -> BTreeMap<&VarName, &Value> {
        self.map
            .iter()
            .map(|(name, (value, _))| (name, value))
            .collect()
    }

    pub(crate) fn get(&self, name: &VarName) -> Option<&Value> {
        self.map.get(name).map(|(value, _)| value)
    }

    pub(crate) fn text(&self, name: &VarName) -> Option<&str> {
        self.get(name).and_then(Value::as_str)
    }

    pub fn set(&mut self, name: &VarName, value: Value) -> Result<bool, Refusal> {
        let old = self.map.get(name);
        if old.is_some_and(|(old, _)| *old == value) {
            return Ok(false);
        }
        let size = serde_json::to_vec(&value).map_or(usize::MAX, |bytes| bytes.len());
        if size > MAX_VALUE {
            return Err(Refusal::ValueTooLarge);
        }
        if old.is_none() && self.map.len() >= MAX_NAMES {
            return Err(Refusal::TooManyNames);
        }
        let weight = name.as_str().len().saturating_add(size);
        let total = self
            .bytes
            .saturating_sub(old.map_or(0, |(_, weight)| *weight))
            .saturating_add(weight);
        if total > MAX_TOTAL {
            return Err(Refusal::TotalTooLarge);
        }
        self.bytes = total;
        self.map.insert(name.clone(), (value, weight));
        Ok(true)
    }

    pub fn remove(&mut self, name: &VarName) -> bool {
        match self.map.remove(name) {
            Some((_, weight)) => {
                self.bytes = self.bytes.saturating_sub(weight);
                true
            }
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name(text: &str) -> VarName {
        VarName::new(text).unwrap()
    }

    fn text(len: usize) -> Value {
        Value::String("x".repeat(len))
    }

    #[test]
    fn a_value_of_the_limit_in_json_passes_and_one_more_byte_does_not() {
        let mut vars = Vars::default();
        assert_eq!(vars.set(&name("a"), text(MAX_VALUE - 2)), Ok(true));
        assert_eq!(
            vars.set(&name("b"), text(MAX_VALUE - 1)),
            Err(Refusal::ValueTooLarge)
        );
        assert_eq!(vars.set(&name("a"), text(MAX_VALUE - 2)), Ok(false));
    }

    #[test]
    fn the_total_and_the_name_count_are_limited_and_a_replacement_frees_its_old_value() {
        let mut vars = Vars::default();
        for index in 0..7 {
            assert_eq!(
                vars.set(&name(&format!("v{index}")), text(MAX_VALUE - 100)),
                Ok(true)
            );
        }
        assert_eq!(vars.set(&name("last"), text(MAX_VALUE - 100)), Ok(true));
        assert_eq!(
            vars.set(&name("one more"), text(40_000)),
            Err(Refusal::TotalTooLarge)
        );
        assert!(vars.remove(&name("last")));
        assert!(!vars.remove(&name("last")));
        assert_eq!(vars.set(&name("one more"), text(40_000)), Ok(true));
        assert_eq!(vars.set(&name("v0"), text(1)), Ok(true));

        let mut vars = Vars::default();
        for index in 0..MAX_NAMES {
            assert_eq!(vars.set(&name(&format!("n{index}")), Value::Null), Ok(true));
        }
        assert_eq!(
            vars.set(&name("extra"), Value::Null),
            Err(Refusal::TooManyNames)
        );
        assert_eq!(vars.set(&name("n0"), Value::Bool(true)), Ok(true));
    }
}
