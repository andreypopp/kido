use std::fmt;

use schemars::{JsonSchema, Schema, SchemaGenerator};
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::http::Status;
use crate::ids::PaneId;
use crate::protocol;

pub(crate) type SchemaFn = fn(&mut SchemaGenerator) -> Schema;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Invalid {
    NoRoute,
    Message(String),
}

impl Invalid {
    pub(crate) fn message(message: impl Into<String>) -> Invalid {
        Invalid::Message(message.into())
    }
}

impl fmt::Display for Invalid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Invalid::NoRoute => f.write_str("resource not found"),
            Invalid::Message(message) => f.write_str(message),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Method {
    Get,
    Put,
    Post,
    Delete,
}

impl Method {
    pub(crate) const GET: Method = Method::Get;
    pub(crate) const PUT: Method = Method::Put;
    pub(crate) const POST: Method = Method::Post;
    pub(crate) const DELETE: Method = Method::Delete;
    pub(crate) const WS: Method = Method::Get;

    pub(crate) fn http(self) -> &'static str {
        match self {
            Method::Get => "GET",
            Method::Put => "PUT",
            Method::Post => "POST",
            Method::Delete => "DELETE",
        }
    }
}

pub(crate) fn captures<'a>(
    template: &'static str,
    path: &'a str,
) -> Option<impl Iterator<Item = &'a str>> {
    let mut parts = path.strip_prefix('/')?.split('/');
    for shape in template.strip_prefix('/')?.split('/') {
        let part = parts.next()?;
        if !shape.starts_with('{') && part != shape {
            return None;
        }
    }
    parts.next().is_none().then(|| {
        path.split('/')
            .skip(1)
            .zip(template.split('/').skip(1))
            .filter(|(_, shape)| shape.starts_with('{'))
            .map(|(part, _)| part)
    })
}

type Pairs<'a> = Vec<(&'a str, &'a str)>;

pub(crate) fn split_target(target: &str) -> Result<(&str, Pairs<'_>), Invalid> {
    let mut parts = target.split('?');
    let path = parts.next().unwrap_or_default();
    let query = parts.next();
    if parts.next().is_some() {
        return Err(Invalid::message("invalid target"));
    }
    let args = match query {
        None => Vec::new(),
        Some(query) => query
            .split('&')
            .map(|pair| {
                let mut sides = pair.split('=');
                match (sides.next(), sides.next(), sides.next()) {
                    (Some(key), Some(value), None) => Ok((key, value)),
                    _ => Err(Invalid::message("invalid query")),
                }
            })
            .collect::<Result<_, _>>()?,
    };
    Ok((path, args))
}

pub(crate) fn arg<'a>(query: &[(&str, &'a str)], name: &str) -> Option<&'a str> {
    query
        .iter()
        .find(|(key, _)| *key == name)
        .map(|(_, value)| *value)
}

pub(crate) trait Param: Sized {
    const EXAMPLE: &'static str;

    fn parse(value: &str) -> Result<Self, Invalid>;
    fn render(&self) -> String;

    fn schema(generator: &mut SchemaGenerator) -> Schema;

    fn absent() -> Option<Self> {
        None
    }

    fn pane(&self) -> Option<PaneId> {
        None
    }
}

impl<T: Param> Param for Option<T> {
    const EXAMPLE: &'static str = T::EXAMPLE;

    fn parse(value: &str) -> Result<Option<T>, Invalid> {
        T::parse(value).map(Some)
    }

    fn render(&self) -> String {
        self.as_ref().map(T::render).unwrap_or_default()
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        T::schema(generator)
    }

    fn absent() -> Option<Option<T>> {
        Some(None)
    }
}

pub(crate) fn query<T: Param>(value: Option<&str>, default: Option<T>) -> Result<T, Invalid> {
    match value {
        Some(value) => T::parse(value),
        None => default
            .or_else(T::absent)
            .ok_or_else(|| Invalid::message("missing parameter")),
    }
}

pub(crate) fn push_query<T: Param + PartialEq>(
    target: &mut String,
    name: &str,
    value: &T,
    default: Option<T>,
) {
    if default.or_else(T::absent).as_ref() != Some(value) {
        target.push(if target.contains('?') { '&' } else { '?' });
        target.push_str(name);
        target.push('=');
        target.push_str(&value.render());
    }
}

pub(crate) trait Body: Sized {
    const OVERSIZED: &'static str = "body exceeds 1 MiB";

    fn decode(payload: Option<&[u8]>) -> Result<Self, Invalid>;
}

impl<T: Serialize + DeserializeOwned> Body for T {
    fn decode(payload: Option<&[u8]>) -> Result<T, Invalid> {
        let bytes = payload.ok_or_else(|| Invalid::message(Self::OVERSIZED))?;
        protocol::decode(bytes).map_err(|error| Invalid::message(error.to_string()))
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Content {
    Json(SchemaFn),
    Text,
    Binary,
    Pixels(SchemaFn),
}

pub(crate) trait Media {
    const CONTENT: Content;
}

pub(crate) fn json<T: JsonSchema>(generator: &mut SchemaGenerator) -> Schema {
    generator.subschema_for::<T>()
}

impl<T: JsonSchema> Media for T {
    const CONTENT: Content = Content::Json(json::<T>);
}

#[allow(non_camel_case_types)]
#[derive(Debug)]
pub(crate) struct text;

impl Media for text {
    const CONTENT: Content = Content::Text;
}

#[allow(non_camel_case_types)]
#[derive(Debug)]
pub(crate) struct binary;

impl Media for binary {
    const CONTENT: Content = Content::Binary;
}

// An image frame: the pixels as a body, or a JSON description of a shared memory object.
#[allow(non_camel_case_types)]
#[derive(Debug)]
pub(crate) struct pixels;

impl Media for pixels {
    const CONTENT: Content = Content::Pixels(json::<protocol::ImageShm>);
}

pub(crate) trait Endpoint {
    type Reply;
}

pub(crate) trait Alt<const CODE: u16>: Endpoint {
    const STATUS: Status;
    type Body;
}

#[allow(clippy::panic)]
pub(crate) const fn declared(code: u16) -> Status {
    match Status::of(code) {
        Some(status) => status,
        None => panic!("an error status of a route must be a known status"),
    }
}

pub(crate) fn no_body(payload: Option<&[u8]>) -> Result<(), Invalid> {
    match payload {
        Some([]) => Ok(()),
        _ => Err(Invalid::message("this route takes no body")),
    }
}

#[derive(Debug)]
pub(crate) struct ParamInfo {
    pub(crate) name: &'static str,
    pub(crate) schema: SchemaFn,
    pub(crate) example: &'static str,
    pub(crate) default: Option<fn() -> String>,
}

#[derive(Debug)]
pub(crate) enum Kind {
    Http {
        reply: Option<Content>,
        errors: &'static [(u16, SchemaFn)],
    },
    Ws {
        send: SchemaFn,
        recv: &'static [Content],
    },
}

#[derive(Debug)]
pub(crate) struct RouteInfo {
    pub(crate) name: &'static str,
    pub(crate) method: Method,
    pub(crate) path: &'static str,
    pub(crate) docs: &'static [&'static str],
    pub(crate) path_params: &'static [ParamInfo],
    pub(crate) query: &'static [ParamInfo],
    pub(crate) body: Option<SchemaFn>,
    pub(crate) caller: Caller,
    pub(crate) kind: Kind,
}

// Whether the route reads the calling pane from the Ko-Pane headers. Named takes Ko-Pane alone
// and requires it: Kido.app has no token, and names the pane that its user prompts from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Caller {
    Absent,
    Optional,
    Named,
}

macro_rules! caller_of {
    () => {
        $crate::route::Caller::Absent
    };
    (optional) => {
        $crate::route::Caller::Optional
    };
    (named) => {
        $crate::route::Caller::Named
    };
}
pub(crate) use caller_of;

macro_rules! error_body {
    () => {
        $crate::protocol::Error
    };
    ($body:ty) => {
        $body
    };
}
pub(crate) use error_body;

macro_rules! kind {
    (WS { reply: [], errors: [], send: [$send:ty], recv: [$($recv:ty),+] }) => {
        $crate::route::Kind::Ws {
            send: $crate::route::json::<$send>,
            recv: &[$(<$recv as $crate::route::Media>::CONTENT),+],
        }
    };
    (WS $($rest:tt)*) => {
        compile_error!("a WS route declares send and recv, and no reply or errors")
    };
    ($method:ident {
        reply: [$($reply:ty)?],
        errors: [$($es:literal $(: $et:ty)?),*],
        send: [],
        recv: []
    }) => {
        $crate::route::Kind::Http {
            reply: $crate::route::reply_of!($($reply)?),
            errors: &[$(($es, $crate::route::json::<$crate::route::error_body!($($et)?)>)),*],
        }
    };
}
pub(crate) use kind;

macro_rules! reply_of {
    () => {
        None
    };
    ($reply:ty) => {
        Some(<$reply as $crate::route::Media>::CONTENT)
    };
}
pub(crate) use reply_of;

macro_rules! body_of {
    () => {
        None
    };
    ($body:ty) => {
        Some($crate::route::json::<$body>)
    };
}
pub(crate) use body_of;

macro_rules! default_of {
    ($ty:ty) => {
        None
    };
    ($ty:ty, $default:ident) => {
        Some(|| $crate::route::Param::render(&<$ty>::$default))
    };
}
pub(crate) use default_of;

macro_rules! decoded {
    ($payload:expr) => {
        $crate::route::no_body($payload)?
    };
    ($payload:expr, $body:ty) => {
        <$body as $crate::route::Body>::decode($payload)?
    };
}
pub(crate) use decoded;

macro_rules! routes {
    ($(
        $(#[doc = $doc:literal])*
        $name:ident {
            method: $method:ident,
            path: $( / $( $lit:ident )? $( { $pn:ident : $pt:ty } )? )*
            $(, query: { $( $qn:ident : $qt:ty $( = $qd:ident )? ),* $(,)? } )?
            $(, body: $bt:ty )?
            $(, caller: $caller:ident )?
            $(, reply: $reply:ty )?
            $(, errors: { $( $es:literal $( : $et:ty )? ),* $(,)? } )?
            $(, send: $send:ty, recv: $recv:ty $( | $more:ty )* )?
            $(,)?
        }
    )*) => {
        #[derive(Debug, Clone, PartialEq, Eq)]
        pub enum Route {
            $(
                $(#[doc = $doc])*
                $name { $( $( $pn: $pt, )? )* $( $( $qn: $qt, )* )? },
            )*
        }

        #[derive(Debug, Clone, PartialEq, Eq)]
        pub(crate) enum Request {
            $(
                $(#[doc = $doc])*
                $name { $( $( $pn: $pt, )? )* $( $( $qn: $qt, )* )? $( body: $bt, )? },
            )*
        }

        pub(crate) mod routes {
            $( $(
                #[doc = concat!("The route replies with ", stringify!($reply), ".")]
                #[derive(Debug)]
                pub(crate) enum $name {}
            )? )*
        }

        $(
            $(
                impl $crate::route::Endpoint for routes::$name {
                    type Reply = $reply;
                }
            )?
            $( $(
                impl $crate::route::Alt<$es> for routes::$name {
                    const STATUS: $crate::http::Status = $crate::route::declared($es);
                    type Body = $crate::route::error_body!($($et)?);
                }
            )* )?
        )*

        pub(crate) const ROUTES: &[$crate::route::RouteInfo] = &[
            $(
                $crate::route::RouteInfo {
                    name: stringify!($name),
                    method: $crate::route::Method::$method,
                    path: concat!( $( "/", $( stringify!($lit), )? $( "{", stringify!($pn), "}", )? )* ),
                    docs: &[ $( $doc, )* ],
                    path_params: &[ $( $(
                        $crate::route::ParamInfo {
                            name: stringify!($pn),
                            schema: <$pt as $crate::route::Param>::schema,
                            example: <$pt as $crate::route::Param>::EXAMPLE,
                            default: None,
                        },
                    )? )* ],
                    query: &[ $( $(
                        $crate::route::ParamInfo {
                            name: stringify!($qn),
                            schema: <$qt as $crate::route::Param>::schema,
                            example: <$qt as $crate::route::Param>::EXAMPLE,
                            default: $crate::route::default_of!($qt $(, $qd)?),
                        },
                    )* )? ],
                    body: $crate::route::body_of!($($bt)?),
                    caller: $crate::route::caller_of!($($caller)?),
                    kind: $crate::route::kind!($method {
                        reply: [$($reply)?],
                        errors: [$($($es $(: $et)?),*)?],
                        send: [$($send)?],
                        recv: [$($recv $(, $more)*)?]
                    }),
                },
            )*
        ];

        impl Route {
            pub fn of_request(method: &str, target: &str) -> Result<Route, $crate::route::Invalid> {
                let (path, query) = $crate::route::split_target(target)?;
                Route::parse(method, path, &query)
            }

            #[allow(unused_mut, unused_variables)]
            fn parse(
                method: &str,
                path: &str,
                query: &[(&str, &str)],
            ) -> Result<Route, $crate::route::Invalid> {
                $(
                    if let Some(mut captured) = $crate::route::captures(
                        concat!( $( "/", $( stringify!($lit), )? $( "{", stringify!($pn), "}", )? )* ),
                        path,
                    ) {
                        $( $(
                            let $pn = <$pt as $crate::route::Param>::parse(
                                captured.next().unwrap_or_default(),
                            )?;
                        )? )*
                        if method == $crate::route::Method::$method.http() {
                            return Ok(Route::$name {
                                $( $( $pn, )? )*
                                $( $(
                                    $qn: $crate::route::query::<$qt>(
                                        $crate::route::arg(query, stringify!($qn)),
                                        None $( .or(Some(<$qt>::$qd)) )?,
                                    )?,
                                )* )?
                            });
                        }
                    }
                )*
                Err($crate::route::Invalid::NoRoute)
            }

            #[allow(unused_mut)]
            pub fn to_request(&self) -> (&'static str, String) {
                match self {
                    $(
                        Route::$name { $( $( $pn, )? )* $( $( $qn, )* )? } => {
                            let mut target = String::new();
                            $(
                                $( target.push('/'); target.push_str(stringify!($lit)); )?
                                $( target.push('/'); target.push_str(&$crate::route::Param::render($pn)); )?
                            )*
                            $( $(
                                $crate::route::push_query::<$qt>(
                                    &mut target,
                                    stringify!($qn),
                                    $qn,
                                    None $( .or(Some(<$qt>::$qd)) )?,
                                );
                            )* )?
                            ($crate::route::Method::$method.http(), target)
                        }
                    )*
                }
            }

            pub fn websocket(&self) -> bool {
                let name = self.name();
                ROUTES.iter().any(|info| {
                    info.name == name && matches!(info.kind, $crate::route::Kind::Ws { .. })
                })
            }

            pub(crate) fn caller(&self) -> $crate::route::Caller {
                let name = self.name();
                ROUTES
                    .iter()
                    .find(|info| info.name == name)
                    .map_or($crate::route::Caller::Absent, |info| info.caller)
            }

            fn name(&self) -> &'static str {
                match self {
                    $( Route::$name { .. } => stringify!($name), )*
                }
            }

            #[allow(unused_variables)]
            pub(crate) fn pane(&self) -> Option<$crate::ids::PaneId> {
                match self {
                    $(
                        Route::$name { $( $( $pn, )? )* .. } => {
                            None $( $( .or($crate::route::Param::pane($pn)) )? )*
                        }
                    )*
                }
            }

            #[allow(unused_variables)]
            pub(crate) fn with_body(
                self,
                payload: Option<&[u8]>,
            ) -> Result<Request, $crate::route::Invalid> {
                Ok(match self {
                    $(
                        Route::$name { $( $( $pn, )? )* $( $( $qn, )* )? } => {
                            let body = $crate::route::decoded!(payload $(, $bt)?);
                            Request::$name {
                                $( $( $pn, )? )*
                                $( $( $qn, )* )?
                                $( body: $crate::route::same::<$bt>(body), )?
                            }
                        }
                    )*
                })
            }
        }
    };
}
pub(crate) use routes;

pub(crate) fn same<T>(value: T) -> T {
    value
}
