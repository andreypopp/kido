use schemars::generate::SchemaSettings;
use schemars::transform::{RemoveRefSiblings, RestrictFormats, Transform, transform_subschemas};
use schemars::{Schema, SchemaGenerator};
use serde_json::{Map, Value, json};

use crate::api::ROUTES;
use crate::http::Status;
use crate::ids::{PaneId, PaneToken};
use crate::protocol;
use crate::route::{Caller, Content, Kind, Param, ParamInfo, RouteInfo};

#[derive(Debug, Clone)]
struct Tidy;

impl Transform for Tidy {
    fn transform(&mut self, schema: &mut Schema) {
        transform_subschemas(self, schema);
        let required: Vec<String> = schema
            .get("required")
            .and_then(Value::as_array)
            .map(|names| {
                names
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        let Some(properties) = schema.get_mut("properties").and_then(Value::as_object_mut) else {
            return;
        };
        let mut sent = Vec::new();
        for (name, property) in properties.iter_mut() {
            if property
                .as_object_mut()
                .and_then(|object| object.remove("x-always-sent"))
                .is_some()
            {
                sent.push(Value::String(name.clone()));
            } else if !required.contains(name) {
                without_null(property);
            }
        }
        if !sent.is_empty() {
            let mut names: Vec<Value> = required.into_iter().map(Value::String).collect();
            names.extend(sent);
            schema.insert("required".to_owned(), Value::Array(names));
        }
    }
}

fn without_null(property: &mut Value) {
    let null = json!({"type": "null"});
    let kept = match property
        .get("anyOf")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
    {
        Some([first, second]) if *second == null => Some(first.clone()),
        Some([first, second]) if *first == null => Some(second.clone()),
        _ => None,
    };
    if let Some(kept) = kept {
        *property = kept;
        return;
    }
    let kept = match property
        .get("type")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
    {
        Some([kept, Value::String(name)]) if name == "null" => Some(kept.clone()),
        _ => None,
    };
    if let (Some(kept), Some(object)) = (kept, property.as_object_mut()) {
        object.insert("type".to_owned(), kept);
    }
}

const BINARY_STREAM: &str = "The pane's terminal byte stream: one application/octet-stream message, framed as in docs/protocol.md section 4.";

fn parameter(
    generator: &mut SchemaGenerator,
    location: &str,
    param: &ParamInfo,
    required: bool,
) -> Value {
    let mut schema = (param.schema)(generator).to_value();
    let integer = schema.get("type") == Some(&json!("integer"));
    if let (Some(default), Some(object)) = (param.default, schema.as_object_mut()) {
        let text = default();
        let default = if integer {
            serde_json::from_str(&text).unwrap_or(Value::String(text))
        } else {
            Value::String(text)
        };
        object.insert("default".to_owned(), default);
    }
    json!({
        "name": param.name,
        "in": location,
        "required": required,
        "example": param.example,
        "schema": schema,
    })
}

fn message(generator: &mut SchemaGenerator, content: Content) -> Value {
    match content {
        Content::Json(schema) => schema(generator).to_value(),
        Content::Text => json!({"type": "string"}),
        Content::Binary => {
            json!({"contentMediaType": "application/octet-stream", "description": BINARY_STREAM})
        }
        Content::Pixels(schema) => schema(generator).to_value(),
    }
}

fn operation(generator: &mut SchemaGenerator, route: &RouteInfo) -> Value {
    let mut operation = Map::new();
    operation.insert("operationId".to_owned(), json!(route.name));
    let description: Vec<&str> = route.docs.iter().map(|line| line.trim()).collect();
    operation.insert("description".to_owned(), json!(description.join(" ")));
    let caller = ParamInfo {
        name: "Ko-Pane",
        schema: <PaneId as Param>::schema,
        example: <PaneId as Param>::EXAMPLE,
        default: None,
    };
    let token = ParamInfo {
        name: "Ko-Pane-Token",
        schema: |generator| generator.subschema_for::<PaneToken>(),
        example: "0123456789abcdef0123456789abcdef",
        default: None,
    };
    let caller: Vec<_> = match route.caller {
        Caller::Absent => Vec::new(),
        Caller::Optional => vec![(&caller, "header", false), (&token, "header", false)],
    };
    let parameters: Vec<Value> = route
        .path_params
        .iter()
        .map(|param| (param, "path", true))
        .chain(route.query.iter().map(|param| (param, "query", false)))
        .chain(caller)
        .map(|(param, location, required)| parameter(generator, location, param, required))
        .collect();
    if !parameters.is_empty() {
        operation.insert("parameters".to_owned(), Value::Array(parameters));
    }
    if let Some(body) = route.body {
        operation.insert(
            "requestBody".to_owned(),
            json!({
                "required": true,
                "content": {"application/json": {"schema": body(generator).to_value()}},
            }),
        );
    }
    let mut responses = Map::new();
    match &route.kind {
        Kind::Ws { send, recv } => {
            responses.insert(
                "101".to_owned(),
                json!({"description": Status::SwitchingProtocols.reason()}),
            );
            let received: Vec<Value> = recv
                .iter()
                .map(|content| message(generator, *content))
                .collect();
            let received = match received.as_slice() {
                [only] => only.clone(),
                _ => json!({"oneOf": received}),
            };
            operation.insert(
                "x-ko-websocket".to_owned(),
                json!({"send": send(generator).to_value(), "recv": received}),
            );
        }
        Kind::Http { reply, errors } => {
            match reply {
                Some(Content::Json(schema)) => {
                    responses.insert(
                        "200".to_owned(),
                        json!({
                            "description": Status::Ok.reason(),
                            "content": {"application/json": {"schema": schema(generator).to_value()}},
                        }),
                    );
                }
                Some(Content::Text) => {
                    responses.insert(
                        "200".to_owned(),
                        json!({
                            "description": Status::Ok.reason(),
                            "content": {"text/plain": {"schema": {"type": "string"}}},
                        }),
                    );
                }
                Some(Content::Pixels(schema)) => {
                    responses.insert(
                        "200".to_owned(),
                        json!({
                            "description": Status::Ok.reason(),
                            "content": {
                                "application/octet-stream": {"schema": {"type": "string", "contentMediaType": "application/octet-stream"}},
                                "application/json": {"schema": schema(generator).to_value()},
                            },
                        }),
                    );
                }
                Some(Content::Binary) | None => {}
            }
            for (status, schema) in *errors {
                responses.insert(
                    status.to_string(),
                    json!({
                        "description": Status::of(*status).map(Status::reason),
                        "content": {"application/json": {"schema": schema(generator).to_value()}},
                    }),
                );
            }
        }
    }
    responses.insert(
        "default".to_owned(),
        json!({
            "description": "The common error body.",
            "content": {
                "application/json": {
                    "schema": generator.subschema_for::<protocol::Error>().to_value(),
                },
            },
        }),
    );
    operation.insert("responses".to_owned(), Value::Object(responses));
    Value::Object(operation)
}

pub fn openapi() -> String {
    serde_json::to_string_pretty(&document()).unwrap_or_default()
}

pub fn generator() -> SchemaGenerator {
    SchemaSettings::draft2020_12()
        .with(|settings| {
            settings.definitions_path = "/components/schemas".into();
            settings
                .transforms
                .push(Box::new(RemoveRefSiblings::default()));
            let mut formats = RestrictFormats::default();
            formats.infer_from_meta_schema = false;
            formats.allowed_formats.insert("date-time".into());
            settings.transforms.push(Box::new(formats));
            settings.transforms.push(Box::new(Tidy));
        })
        .into_generator()
}

pub fn components() -> Map<String, Value> {
    let mut document = document();
    match document["components"]["schemas"].take() {
        Value::Object(components) => components,
        _ => Map::new(),
    }
}

fn document() -> Value {
    let mut generator = generator();
    let mut paths = Map::new();
    for route in ROUTES {
        let item = paths
            .entry(route.path.to_owned())
            .or_insert_with(|| Value::Object(Map::new()));
        if let Some(item) = item.as_object_mut() {
            item.insert(
                route.method.http().to_ascii_lowercase(),
                operation(&mut generator, route),
            );
        }
    }
    json!({
        "openapi": "3.1.0",
        "info": {
            "title": "ko server",
            "version": protocol::version().protocol,
            "description": "The HTTP and WebSocket interface of the ko server on its unix socket.",
        },
        "paths": paths,
        "components": {"schemas": generator.take_definitions(true)},
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn references(value: &Value, found: &mut Vec<String>) {
        match value {
            Value::Object(object) => {
                for (key, value) in object {
                    match value {
                        Value::String(target) if key == "$ref" => found.push(target.clone()),
                        _ => references(value, found),
                    }
                }
            }
            Value::Array(items) => items.iter().for_each(|item| references(item, found)),
            _ => {}
        }
    }

    #[test]
    fn every_route_is_an_operation_and_every_reference_names_a_component() {
        let document = document();
        for route in ROUTES {
            let operation =
                &document["paths"][route.path][route.method.http().to_ascii_lowercase()];
            assert_eq!(operation["operationId"], route.name, "{}", route.path);
            assert_eq!(
                operation.get("x-ko-websocket").is_some(),
                matches!(route.kind, Kind::Ws { .. }),
                "{}",
                route.name
            );
            assert!(
                operation["responses"]["default"].is_object(),
                "{}",
                route.name
            );
        }
        let mut found = Vec::new();
        references(&document, &mut found);
        let schemas = &document["components"]["schemas"];
        for target in found {
            let name = target
                .strip_prefix("#/components/schemas/")
                .unwrap_or(&target);
            assert!(schemas.get(name).is_some(), "{target}");
        }
        assert_eq!(document["info"]["version"], protocol::version().protocol);
    }
}
