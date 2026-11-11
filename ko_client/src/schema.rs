use ko_wire::protocol;
use ko_wire::schema;
use serde_json::{Value, json};

use crate::edit::Edit;
use crate::layout::Edited;
use crate::model::ModelJson;

pub fn client_model() -> Result<String, String> {
    let mut generator = schema::generator();
    generator.subschema_for::<ModelJson>();
    generator.subschema_for::<Edit>();
    generator.subschema_for::<Edited>();
    let server = schema::components();
    let mut own = serde_json::Map::new();
    for (name, definition) in generator.take_definitions(true) {
        match server.get(&name) {
            Some(known) if *known != definition => {
                return Err(format!("{name} differs from the server's schema"));
            }
            Some(_) => {}
            None => {
                own.insert(name, definition);
            }
        }
    }
    let document = json!({
        "info": {
            "title": "ko client model",
            "version": protocol::version().protocol,
            "description": "The JSON of ko_client_model and of ko_client_edit. References name the components of the server's OpenAPI document.",
        },
        "components": {"schemas": Value::Object(own)},
    });
    serde_json::to_string_pretty(&document).map_err(|error| error.to_string())
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
    fn every_reference_names_a_component_of_the_client_or_the_server_document() {
        let document: Value = serde_json::from_str(&client_model().unwrap()).unwrap();
        let own = document["components"]["schemas"].as_object().unwrap();
        let server = schema::components();
        let mut found = Vec::new();
        references(&document, &mut found);
        for target in found {
            let name = target.strip_prefix("#/components/schemas/").unwrap();
            assert!(
                own.contains_key(name) || server.contains_key(name),
                "{target}"
            );
        }
        assert!(
            ["ModelJson", "Edit", "Edited"]
                .iter()
                .all(|name| own.contains_key(*name))
        );
    }
}
