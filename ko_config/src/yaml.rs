use std::collections::{HashMap, HashSet};
use std::fmt;
use std::rc::Rc;

use saphyr_parser::{Event, Marker, Parser, ScalarStyle};
use serde::Serialize;
use serde::de::value::StrDeserializer;
use serde::de::{
    self, DeserializeOwned, DeserializeSeed, EnumAccess, IntoDeserializer, MapAccess, SeqAccess,
    Unexpected, VariantAccess, Visitor,
};

const MAX_DEPTH: usize = 64;
const MAX_NODES: usize = 100_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Pos {
    line: usize,
    column: usize,
}

impl Pos {
    fn of(mark: Marker) -> Pos {
        Pos {
            line: mark.line(),
            column: mark.col() + 1,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Problem {
    pub line: usize,
    pub column: usize,
    pub message: String,
}

impl fmt::Display for Problem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} at line {} column {}",
            self.message, self.line, self.column
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Error {
    at: Option<Pos>,
    path: Vec<String>,
    message: String,
}

impl Error {
    fn text(&self) -> String {
        let mut text = String::new();
        for key in &self.path {
            text.push_str(key);
            text.push_str(": ");
        }
        text.push_str(&self.message);
        text
    }

    fn into_problem(self, fallback: Pos) -> Problem {
        let Pos { line, column } = self.at.unwrap_or(fallback);
        Problem {
            line,
            column,
            message: self.text(),
        }
    }

    fn at(self, at: Pos) -> Error {
        Error {
            at: self.at.or(Some(at)),
            ..self
        }
    }

    fn within(mut self, key: &str) -> Error {
        self.path.insert(0, key.to_owned());
        self
    }

    fn here(at: Pos, message: &str) -> Error {
        Error {
            at: Some(at),
            path: Vec::new(),
            message: message.to_owned(),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.at {
            Some(Pos { line, column }) => fmt::Display::fmt(
                &Problem {
                    line,
                    column,
                    message: self.text(),
                },
                f,
            ),
            None => f.write_str(&self.text()),
        }
    }
}

impl std::error::Error for Error {}

impl de::Error for Error {
    fn custom<T: fmt::Display>(message: T) -> Error {
        Error {
            at: None,
            path: Vec::new(),
            message: message.to_string(),
        }
    }
}

#[derive(Debug)]
struct Node {
    at: Pos,
    size: usize,
    depth: usize,
    value: Value,
}

#[derive(Debug)]
enum Value {
    Scalar { text: String, plain: bool },
    List(Vec<Rc<Node>>),
    Map(Vec<Entry>),
}

#[derive(Debug)]
struct Entry {
    key: String,
    at: Pos,
    value: Rc<Node>,
}

impl Node {
    fn new(at: Pos, value: Value) -> Rc<Node> {
        let (size, depth) = match &value {
            Value::Scalar { .. } => (1, 0),
            Value::List(items) => (
                items.iter().fold(1, |sum, item| sum + item.size),
                1 + items.iter().map(|item| item.depth).max().unwrap_or(0),
            ),
            Value::Map(entries) => (
                entries
                    .iter()
                    .fold(1, |sum, entry| sum + 1 + entry.value.size),
                1 + entries
                    .iter()
                    .map(|entry| entry.value.depth)
                    .max()
                    .unwrap_or(0),
            ),
        };
        Rc::new(Node {
            at,
            size,
            depth,
            value,
        })
    }

    fn is_null(&self) -> bool {
        matches!(&self.value, Value::Scalar { text, plain: true }
            if matches!(text.as_str(), "" | "~" | "null" | "Null" | "NULL"))
    }

    fn unexpected(&self) -> Unexpected<'_> {
        match &self.value {
            _ if self.is_null() => Unexpected::Other("null"),
            Value::Scalar { text, .. } => Unexpected::Str(text),
            Value::List(_) => Unexpected::Seq,
            Value::Map(_) => Unexpected::Map,
        }
    }
}

#[derive(Debug)]
enum Frame {
    List {
        at: Pos,
        anchor: usize,
        items: Vec<Rc<Node>>,
    },
    Map {
        at: Pos,
        anchor: usize,
        entries: Vec<Entry>,
        seen: HashSet<String>,
        key: Option<(String, Pos)>,
    },
}

fn tree(text: &str) -> Result<Rc<Node>, Error> {
    let mut anchors: HashMap<usize, Rc<Node>> = HashMap::new();
    let mut stack: Vec<Frame> = Vec::new();
    let mut root: Option<Rc<Node>> = None;
    let mut documents = 0;
    let mut nodes = 0;
    for event in Parser::new_from_str(text) {
        let (event, span) =
            event.map_err(|error| Error::here(Pos::of(*error.marker()), error.info()))?;
        let at = Pos::of(span.start);
        if let Event::Scalar(_, _, _, Some(_))
        | Event::SequenceStart(_, Some(_))
        | Event::MappingStart(_, Some(_)) = event
        {
            return Err(Error::here(at, "tags are not supported"));
        }
        let (anchor, node) = match event {
            Event::DocumentStart(_) => {
                documents += 1;
                if documents > 1 {
                    return Err(Error::here(at, "more than one document"));
                }
                continue;
            }
            Event::Scalar(text, style, anchor, _) => {
                nodes += 1;
                let plain = style == ScalarStyle::Plain;
                let text = text.into_owned();
                (anchor, Node::new(at, Value::Scalar { text, plain }))
            }
            Event::Alias(id) => {
                let node = anchors
                    .get(&id)
                    .ok_or_else(|| Error::here(at, "unknown anchor"))?;
                nodes += node.size;
                if stack.len() + node.depth > MAX_DEPTH {
                    return Err(Error::here(at, &deeper()));
                }
                (0, Rc::clone(node))
            }
            Event::SequenceStart(anchor, _) => {
                nodes += 1;
                if stack.len() >= MAX_DEPTH {
                    return Err(Error::here(at, &deeper()));
                }
                stack.push(Frame::List {
                    at,
                    anchor,
                    items: Vec::new(),
                });
                continue;
            }
            Event::MappingStart(anchor, _) => {
                nodes += 1;
                if stack.len() >= MAX_DEPTH {
                    return Err(Error::here(at, &deeper()));
                }
                stack.push(Frame::Map {
                    at,
                    anchor,
                    entries: Vec::new(),
                    seen: HashSet::new(),
                    key: None,
                });
                continue;
            }
            Event::SequenceEnd => match stack.pop() {
                Some(Frame::List { at, anchor, items }) => {
                    (anchor, Node::new(at, Value::List(items)))
                }
                _ => return Err(Error::here(at, "unbalanced sequence")),
            },
            Event::MappingEnd => match stack.pop() {
                Some(Frame::Map {
                    at,
                    anchor,
                    entries,
                    ..
                }) => (anchor, Node::new(at, Value::Map(entries))),
                _ => return Err(Error::here(at, "unbalanced mapping")),
            },
            Event::Nothing | Event::StreamStart | Event::StreamEnd | Event::DocumentEnd => continue,
        };
        if nodes > MAX_NODES {
            return Err(Error::here(
                at,
                &format!("more than {MAX_NODES} nodes, aliases included"),
            ));
        }
        if anchor != 0 {
            anchors.insert(anchor, Rc::clone(&node));
        }
        match stack.last_mut() {
            None => root = Some(node),
            Some(Frame::List { items, .. }) => items.push(node),
            Some(Frame::Map {
                entries, seen, key, ..
            }) => match key.take() {
                None => match &node.value {
                    Value::Scalar { text, .. } => *key = Some((text.clone(), node.at)),
                    _ => return Err(Error::here(node.at, "a map key must be a scalar")),
                },
                Some((key, at)) => {
                    if !seen.insert(key.clone()) {
                        return Err(Error::here(at, &format!("duplicate key {key:?}")));
                    }
                    entries.push(Entry {
                        key,
                        at,
                        value: node,
                    });
                }
            },
        }
    }
    match root {
        Some(root) if !root.is_null() => Ok(root),
        _ => Ok(Node::new(
            Pos { line: 1, column: 1 },
            Value::Map(Vec::new()),
        )),
    }
}

fn deeper() -> String {
    format!("nesting is deeper than {MAX_DEPTH} levels")
}

fn all_digits(text: &str, radix: u32) -> bool {
    text.chars().all(|c| c.is_digit(radix))
}

fn int(text: &str) -> Option<i128> {
    let (digits, radix) = if let Some(hex) = text.strip_prefix("0x") {
        (hex, 16)
    } else if let Some(octal) = text.strip_prefix("0o") {
        (octal, 8)
    } else {
        (text.strip_prefix(['-', '+']).unwrap_or(text), 10)
    };
    if digits.is_empty() || !all_digits(digits, radix) {
        return None;
    }
    if radix == 10 {
        text.parse().ok()
    } else {
        i128::from_str_radix(digits, radix).ok()
    }
}

fn float(text: &str) -> Option<f64> {
    let unsigned = text.strip_prefix(['-', '+']).unwrap_or(text);
    if matches!(unsigned, ".inf" | ".Inf" | ".INF") {
        return Some(if text.starts_with('-') {
            f64::NEG_INFINITY
        } else {
            f64::INFINITY
        });
    }
    if matches!(text, ".nan" | ".NaN" | ".NAN") {
        return Some(f64::NAN);
    }
    if let Some(number) = int(text) {
        return Some(number as f64);
    }
    let (mantissa, exponent) = match unsigned.find(['e', 'E']) {
        Some(at) => (&unsigned[..at], Some(&unsigned[at + 1..])),
        None => (unsigned, None),
    };
    let (whole, fraction) = match mantissa.split_once('.') {
        Some((whole, fraction)) => (whole, Some(fraction)),
        None => (mantissa, None),
    };
    let shape = all_digits(whole, 10)
        && fraction.is_none_or(|fraction| all_digits(fraction, 10))
        && !(whole.is_empty() && fraction.is_none_or(str::is_empty))
        && exponent.is_none_or(|exponent| {
            let exponent = exponent.strip_prefix(['-', '+']).unwrap_or(exponent);
            !exponent.is_empty() && all_digits(exponent, 10)
        });
    if shape { text.parse().ok() } else { None }
}

#[derive(Debug)]
enum Want {
    Any,
    Bool,
    Int,
    Float,
    Str,
    Option,
    Unit,
    Newtype,
    Seq,
    Map,
    Struct(&'static [&'static str]),
    Enum,
}

impl Node {
    fn decode<'de, V: Visitor<'de>>(&self, want: Want, visitor: V) -> Result<V::Value, Error> {
        let wrong =
            |expected: &dyn de::Expected| Err(de::Error::invalid_type(self.unexpected(), expected));
        let result = match (&want, &self.value) {
            (Want::Option, _) if self.is_null() => visitor.visit_none(),
            (Want::Option, _) => visitor.visit_some(self),
            (Want::Newtype, _) => visitor.visit_newtype_struct(self),
            (Want::Unit, _) if self.is_null() => visitor.visit_unit(),
            (Want::Unit, _) => wrong(&"null"),
            (Want::Any, _) if self.is_null() => visitor.visit_unit(),
            (Want::Any, Value::Scalar { text, plain: true }) if int(text).is_some() => {
                match int(text).map(|number| (i64::try_from(number), u64::try_from(number))) {
                    Some((Ok(number), _)) => visitor.visit_i64(number),
                    Some((_, Ok(number))) => visitor.visit_u64(number),
                    _ => wrong(&visitor),
                }
            }
            (Want::Any, Value::Scalar { text, plain: true }) if float(text).is_some() => {
                visitor.visit_f64(float(text).unwrap_or_default())
            }
            (Want::Any | Want::Str, Value::Scalar { text, .. }) if !self.is_null() => {
                visitor.visit_str(text)
            }
            (Want::Str, _) => wrong(&"a string"),
            (Want::Bool, Value::Scalar { text, plain: true }) => match text.as_str() {
                "true" | "True" | "TRUE" => visitor.visit_bool(true),
                "false" | "False" | "FALSE" => visitor.visit_bool(false),
                _ => wrong(&visitor),
            },
            (Want::Int, Value::Scalar { text, plain: true }) => match int(text) {
                Some(number) => match (i64::try_from(number), u64::try_from(number)) {
                    (Ok(number), _) => visitor.visit_i64(number),
                    (_, Ok(number)) => visitor.visit_u64(number),
                    _ => wrong(&visitor),
                },
                None => wrong(&visitor),
            },
            (Want::Float, Value::Scalar { text, plain: true }) => match float(text) {
                Some(number) => visitor.visit_f64(number),
                None => wrong(&visitor),
            },
            (Want::Any | Want::Seq, Value::List(items)) => visitor.visit_seq(Items {
                items: items.iter().enumerate(),
            }),
            (Want::Any | Want::Map, Value::Map(entries)) => visitor.visit_map(Fields {
                entries: entries.iter(),
                pending: None,
                known: None,
            }),
            (Want::Struct(fields), Value::Map(entries)) => visitor.visit_map(Fields {
                entries: entries.iter(),
                pending: None,
                known: Some(fields),
            }),
            (Want::Enum, Value::Scalar { text, .. }) if !self.is_null() => {
                visitor.visit_enum(Tagged {
                    key: text,
                    at: self.at,
                    value: None,
                })
            }
            (Want::Enum, Value::Map(entries)) => match entries.as_slice() {
                [entry] => visitor.visit_enum(Tagged {
                    key: &entry.key,
                    at: entry.at,
                    value: Some(&entry.value),
                }),
                _ => Err(de::Error::custom("expected a map with one key")),
            },
            (Want::Enum, _) => wrong(&"an enum"),
            (Want::Seq, _) => wrong(&"a list"),
            (Want::Bool | Want::Int | Want::Float | Want::Map | Want::Struct(_) | Want::Any, _) => {
                wrong(&visitor)
            }
        };
        result.map_err(|error| error.at(self.at))
    }
}

macro_rules! want {
    ($($method:ident($($arg:ident: $ty:ty),*) => $want:expr;)*) => {
        $(fn $method<V: Visitor<'de>>(self, $(_: $ty,)* visitor: V) -> Result<V::Value, Error> {
            self.decode($want, visitor)
        })*
    };
}

impl<'de> de::Deserializer<'de> for &Node {
    type Error = Error;

    want! {
        deserialize_any() => Want::Any;
        deserialize_bool() => Want::Bool;
        deserialize_i8() => Want::Int;
        deserialize_i16() => Want::Int;
        deserialize_i32() => Want::Int;
        deserialize_i64() => Want::Int;
        deserialize_u8() => Want::Int;
        deserialize_u16() => Want::Int;
        deserialize_u32() => Want::Int;
        deserialize_u64() => Want::Int;
        deserialize_f32() => Want::Float;
        deserialize_f64() => Want::Float;
        deserialize_char() => Want::Str;
        deserialize_str() => Want::Str;
        deserialize_string() => Want::Str;
        deserialize_bytes() => Want::Str;
        deserialize_byte_buf() => Want::Str;
        deserialize_option() => Want::Option;
        deserialize_unit() => Want::Unit;
        deserialize_unit_struct(_name: &'static str) => Want::Unit;
        deserialize_newtype_struct(_name: &'static str) => Want::Newtype;
        deserialize_seq() => Want::Seq;
        deserialize_tuple(_len: usize) => Want::Seq;
        deserialize_tuple_struct(_name: &'static str, _len: usize) => Want::Seq;
        deserialize_map() => Want::Map;
        deserialize_identifier() => Want::Str;
        deserialize_ignored_any() => Want::Any;
    }

    fn deserialize_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        fields: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, Error> {
        self.decode(Want::Struct(fields), visitor)
    }

    fn deserialize_enum<V: Visitor<'de>>(
        self,
        _name: &'static str,
        _variants: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, Error> {
        self.decode(Want::Enum, visitor)
    }
}

#[derive(Debug)]
struct Items<'a> {
    items: std::iter::Enumerate<std::slice::Iter<'a, Rc<Node>>>,
}

impl<'de> SeqAccess<'de> for Items<'_> {
    type Error = Error;

    fn next_element_seed<T: DeserializeSeed<'de>>(
        &mut self,
        seed: T,
    ) -> Result<Option<T::Value>, Error> {
        let Some((index, item)) = self.items.next() else {
            return Ok(None);
        };
        seed.deserialize(&**item)
            .map(Some)
            .map_err(|error| error.at(item.at).within(&format!("[{index}]")))
    }

    fn size_hint(&self) -> Option<usize> {
        Some(self.items.len())
    }
}

#[derive(Debug)]
struct Fields<'a> {
    entries: std::slice::Iter<'a, Entry>,
    pending: Option<&'a Entry>,
    known: Option<&'static [&'static str]>,
}

impl<'de> MapAccess<'de> for Fields<'_> {
    type Error = Error;

    fn next_key_seed<K: DeserializeSeed<'de>>(
        &mut self,
        seed: K,
    ) -> Result<Option<K::Value>, Error> {
        let known = self.known;
        let Some(entry) = self.entries.find(|entry| {
            !(entry.value.is_null() && known.is_none_or(|k| k.contains(&entry.key.as_str())))
        }) else {
            return Ok(None);
        };
        self.pending = Some(entry);
        let key: StrDeserializer<'_, Error> = entry.key.as_str().into_deserializer();
        seed.deserialize(key)
            .map(Some)
            .map_err(|error| error.at(entry.at))
    }

    fn next_value_seed<V: DeserializeSeed<'de>>(&mut self, seed: V) -> Result<V::Value, Error> {
        let Some(entry) = self.pending.take() else {
            return Err(de::Error::custom("a value without a key"));
        };
        seed.deserialize(&*entry.value)
            .map_err(|error| error.at(entry.value.at).within(&entry.key))
    }
}

#[derive(Debug)]
struct Tagged<'a> {
    key: &'a str,
    at: Pos,
    value: Option<&'a Rc<Node>>,
}

impl Tagged<'_> {
    fn content(&self) -> Result<&Node, Error> {
        self.value
            .map(|node| &**node)
            .ok_or_else(|| Error::here(self.at, "this variant needs content"))
    }
}

impl<'de, 'a> EnumAccess<'de> for Tagged<'a> {
    type Error = Error;
    type Variant = Tagged<'a>;

    fn variant_seed<V: DeserializeSeed<'de>>(self, seed: V) -> Result<(V::Value, Self), Error> {
        let key: StrDeserializer<'_, Error> = self.key.into_deserializer();
        let variant = seed.deserialize(key).map_err(|error| error.at(self.at))?;
        Ok((variant, self))
    }
}

impl<'de> VariantAccess<'de> for Tagged<'_> {
    type Error = Error;

    fn unit_variant(self) -> Result<(), Error> {
        match self.value {
            Some(node) if !node.is_null() => Err(de::Error::invalid_type(
                node.unexpected(),
                &"a variant without content",
            ))
            .map_err(|error: Error| error.at(node.at).within(self.key)),
            _ => Ok(()),
        }
    }

    fn newtype_variant_seed<T: DeserializeSeed<'de>>(self, seed: T) -> Result<T::Value, Error> {
        let node = self.content()?;
        seed.deserialize(node)
            .map_err(|error| error.at(node.at).within(self.key))
    }

    fn tuple_variant<V: Visitor<'de>>(self, _len: usize, visitor: V) -> Result<V::Value, Error> {
        let node = self.content()?;
        node.decode(Want::Seq, visitor)
            .map_err(|error| error.within(self.key))
    }

    fn struct_variant<V: Visitor<'de>>(
        self,
        fields: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, Error> {
        let node = self.content()?;
        node.decode(Want::Struct(fields), visitor)
            .map_err(|error| error.within(self.key))
    }
}

pub(crate) fn from_str<T: DeserializeOwned>(text: &str) -> Result<T, Problem> {
    let start = Pos { line: 1, column: 1 };
    let root = tree(text).map_err(|error| error.into_problem(start))?;
    T::deserialize(&*root).map_err(|error| error.into_problem(root.at))
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use serde::Deserialize;

    use super::*;

    #[derive(Debug, PartialEq, Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Typed {
        #[serde(default)]
        flag: bool,
        #[serde(default)]
        count: i64,
        #[serde(default)]
        ratio: f64,
        #[serde(default)]
        text: String,
        #[serde(default)]
        list: Vec<String>,
        #[serde(default)]
        map: BTreeMap<String, String>,
        #[serde(default)]
        maybe: Option<String>,
    }

    fn typed(text: &str) -> Result<Typed, String> {
        from_str(text).map_err(|error| error.to_string())
    }

    #[test]
    fn strings_keep_the_yaml_1_2_text_of_every_scalar() {
        let found = typed(
            "text: yes\nlist: [-p, 2222, no, on, NO, 0755, 1:20, 0x1f, 1e3, ~x]\nmap: {A: 0755, B: yes, C: 1:20, D: 'null', E: \"\"}\n",
        )
        .unwrap();
        assert_eq!(found.text, "yes");
        assert_eq!(
            found.list,
            [
                "-p", "2222", "no", "on", "NO", "0755", "1:20", "0x1f", "1e3", "~x"
            ]
        );
        let map: Vec<_> = found.map.iter().map(|(k, v)| format!("{k}={v}")).collect();
        assert_eq!(map, ["A=0755", "B=yes", "C=1:20", "D=null", "E="]);
    }

    #[test]
    fn bools_ints_and_floats_follow_the_core_schema() {
        let found = typed("flag: true\ncount: 42\nratio: 0.5\n").unwrap();
        assert_eq!((found.flag, found.count, found.ratio), (true, 42, 0.5));
        let found = typed("flag: FALSE\ncount: 0x1F\nratio: .inf\n").unwrap();
        assert_eq!(
            (found.flag, found.count, found.ratio),
            (false, 31, f64::INFINITY)
        );
        assert_eq!(typed("count: 0o17\nratio: -1.5e2\n").unwrap().count, 15);
        assert_eq!(typed("ratio: 3\n").unwrap().ratio, 3.0);
        for (text, message) in [
            (
                "flag: yes",
                "flag: invalid type: string \"yes\", expected a boolean at line 1 column 7",
            ),
            (
                "flag: 'true'",
                "flag: invalid type: string \"true\", expected a boolean at line 1 column 7",
            ),
            (
                "count: 0755x",
                "count: invalid type: string \"0755x\", expected i64 at line 1 column 8",
            ),
            (
                "count: '4'",
                "count: invalid type: string \"4\", expected i64 at line 1 column 8",
            ),
            (
                "count: 1:20",
                "count: invalid type: string \"1:20\", expected i64 at line 1 column 8",
            ),
            (
                "ratio: 1_0",
                "ratio: invalid type: string \"1_0\", expected f64 at line 1 column 8",
            ),
            (
                "ratio: [1]",
                "ratio: invalid type: sequence, expected f64 at line 1 column 8",
            ),
        ] {
            assert_eq!(typed(text).unwrap_err(), message, "{text}");
        }
    }

    #[test]
    fn a_wrong_node_kind_names_its_field_and_place() {
        assert_eq!(
            typed("text: x\nmap: [a]\n").unwrap_err(),
            "map: invalid type: sequence, expected a map at line 2 column 6"
        );
        assert_eq!(
            typed("list: -p\n").unwrap_err(),
            "list: invalid type: string \"-p\", expected a list at line 1 column 7"
        );
        assert_eq!(
            typed("list: [a, {b: c}]\n").unwrap_err(),
            "list: [1]: invalid type: map, expected a string at line 1 column 11"
        );
        assert_eq!(
            typed("text: [a]\n").unwrap_err(),
            "text: invalid type: sequence, expected a string at line 1 column 7"
        );
        assert_eq!(
            typed("- a\n").unwrap_err(),
            "invalid type: sequence, expected struct Typed at line 1 column 1"
        );
    }

    #[test]
    fn a_null_is_a_missing_key_and_a_null_in_an_option_is_none() {
        for text in [
            "text:\n",
            "text: ~\n",
            "text: null\n",
            "text: Null\n",
            "text: NULL\n",
        ] {
            assert_eq!(typed(text).unwrap().text, "", "{text}");
        }
        assert_eq!(typed("text: ''\nmaybe: ~\n").unwrap().maybe, None);
        assert_eq!(typed("maybe: ~x\n").unwrap().maybe.as_deref(), Some("~x"));
        assert_eq!(typed("map: {A: , B: x}\n").unwrap().map.len(), 1);
        assert_eq!(
            typed("nope:\n").unwrap_err(),
            "unknown field `nope`, expected one of `flag`, `count`, `ratio`, `text`, `list`, `map`, `maybe` at line 1 column 1"
        );
    }

    #[test]
    fn an_empty_file_and_a_file_of_comments_decode_like_an_empty_map() {
        for text in ["", "# nothing\n", "\u{feff}# nothing\n", "---\n", "~\n"] {
            assert_eq!(typed(text), typed("{}"), "{text:?}");
        }
        assert_eq!(typed("\u{feff}text: a\n").unwrap().text, "a");
    }

    #[test]
    fn a_parse_error_has_its_line_and_column() {
        let error = typed("text: a\nlist: [b\n").unwrap_err();
        assert!(error.ends_with("line 3 column 1"), "{error}");
        let error = typed("text: a\n  bad: [\n").unwrap_err();
        assert!(error.contains("line 2"), "{error}");
        assert_eq!(
            typed("text: a\ntext: b\n").unwrap_err(),
            "duplicate key \"text\" at line 2 column 1"
        );
        assert_eq!(
            typed("map:\n  A: 1\n  B: 2\n  A: 3\n").unwrap_err(),
            "duplicate key \"A\" at line 4 column 3"
        );
    }

    #[test]
    fn documents_keys_tags_and_anchors_are_limited() {
        assert_eq!(
            typed("text: a\n---\ntext: b\n").unwrap_err(),
            "more than one document at line 2 column 1"
        );
        assert_eq!(
            typed("? [a]\n: b\n").unwrap_err(),
            "a map key must be a scalar at line 1 column 3"
        );
        assert_eq!(
            typed("text: !!str 1\n").unwrap_err(),
            "tags are not supported at line 1 column 7"
        );
        assert_eq!(
            typed("text: !x [a]\n").unwrap_err(),
            "tags are not supported at line 1 column 7"
        );
        assert_eq!(
            typed("text: &a x\nmaybe: *a\n").unwrap().maybe.as_deref(),
            Some("x")
        );
        assert_eq!(
            typed("list: &l [a]\nmap: {k: x}\ntext: *l\n").unwrap_err(),
            "text: invalid type: sequence, expected a string at line 1 column 7"
        );
        assert_eq!(
            typed("<<: x\n").unwrap_err().split(',').next().unwrap(),
            "unknown field `<<`"
        );
    }

    #[test]
    fn a_large_map_without_duplicates_decodes_and_a_flat_file_over_the_node_cap_is_refused() {
        let text: String = (0..40_000).map(|key| format!("k{key}: v\n")).collect();
        assert_eq!(
            from_str::<BTreeMap<String, String>>(&text).unwrap().len(),
            40_000
        );
        let flat = format!("[{}]", vec!["x"; MAX_NODES].join(","));
        assert_eq!(
            from_str::<Vec<String>>(&flat).unwrap_err().to_string(),
            "more than 100000 nodes, aliases included at line 1 column 200000"
        );
    }

    #[test]
    fn a_unit_variant_with_content_names_its_key_and_place() {
        #[derive(Debug, Deserialize)]
        #[serde(rename_all = "snake_case")]
        enum Pi {
            Host,
        }
        #[derive(Debug, Deserialize)]
        struct Holder {
            #[allow(dead_code)]
            pi: Pi,
        }
        assert_eq!(
            from_str::<Holder>("pi: {host: 1}\n")
                .unwrap_err()
                .to_string(),
            "pi: host: invalid type: string \"1\", expected a variant without content at line 1 column 12"
        );
    }

    #[test]
    fn an_alias_bomb_and_deep_nesting_are_refused() {
        let mut bomb = String::from("a0: &a0 [x, x, x, x, x, x, x, x, x, x]\n");
        for level in 1..8 {
            let previous = level - 1;
            let refs = vec![format!("*a{previous}"); 10].join(", ");
            bomb.push_str(&format!("a{level}: &a{level} [{refs}]\n"));
        }
        let error = from_str::<serde::de::IgnoredAny>(&bomb)
            .unwrap_err()
            .to_string();
        assert!(
            error.starts_with("more than 100000 nodes, aliases included at line "),
            "{error}"
        );
        let deep = format!("{}x{}", "[".repeat(65), "]".repeat(65));
        assert!(
            from_str::<serde::de::IgnoredAny>(&deep)
                .unwrap_err()
                .to_string()
                .starts_with("nesting is deeper than 64 levels at line 1 column "),
        );
        let fine = format!("{}x{}", "[".repeat(60), "]".repeat(60));
        assert!(from_str::<serde::de::IgnoredAny>(&fine).is_ok());
    }
}
