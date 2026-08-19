use std::collections::{BTreeMap, HashMap, HashSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use agent_client_protocol::schema::v1::{
    CreateElicitationRequest, ElicitationContentValue, ElicitationMode, ElicitationPropertySchema,
    ElicitationSchema, EnumOption, MultiSelectItems,
};

/// One option in a single- or multi-select ask question.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AskOption {
    pub value: String,
    pub label: String,
}

/// One question the agent is asking the user.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AskQuestion {
    pub id: String,
    pub prompt: String,
    pub description: Option<String>,
    #[serde(rename = "field_type")]
    pub field_type: String,
    pub options: Vec<AskOption>,
    pub required: bool,
}

/// A form-based request for user input sent by the agent.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AskRequest {
    pub request_id: String,
    pub message: String,
    pub questions: Vec<AskQuestion>,
}

/// The user's answer to an ask request.
#[derive(Debug, Clone, Deserialize)]
pub struct AskResponse {
    pub answers: HashMap<String, serde_json::Value>,
}

/// Final result of an ask callback.
#[derive(Debug, Clone)]
pub enum AskOutcome {
    Answers(HashMap<String, serde_json::Value>),
    Cancel,
}

/// Callback the API layer supplies to the provider so ask requests
/// can be forwarded to the client and awaited.
pub type AskCallback = Arc<
    dyn Fn(AskRequest) -> Pin<Box<dyn Future<Output = AskOutcome> + Send>> + Send + Sync,
>;

/// Convert an ACP `elicitation/create` request into a frontend-friendly ask.
/// Returns `None` for unsupported modes (e.g. URL elicitation).
pub fn from_acp(req: &CreateElicitationRequest) -> Option<AskRequest> {
    let ElicitationMode::Form(form) = &req.mode else {
        return None;
    };
    let questions = questions_from_schema(&form.requested_schema);
    if questions.is_empty() {
        return None;
    }
    Some(AskRequest {
        request_id: uuid::Uuid::new_v4().to_string(),
        message: req.message.clone(),
        questions,
    })
}

fn questions_from_schema(schema: &ElicitationSchema) -> Vec<AskQuestion> {
    let required: HashSet<_> = schema
        .required
        .as_ref()
        .map(|r| r.iter().cloned().collect())
        .unwrap_or_default();
    schema
        .properties
        .iter()
        .map(|(id, prop)| question_from_property(id, prop, required.contains(id)))
        .collect()
}

fn question_from_property(
    id: &str,
    prop: &ElicitationPropertySchema,
    required: bool,
) -> AskQuestion {
    match prop {
        ElicitationPropertySchema::String(s) => {
            let (field_type, options) = if let Some(one_of) = s.one_of.as_ref() {
                ("single_select", options_from_enum(one_of))
            } else if let Some(values) = s.enum_values.as_ref() {
                (
                    "single_select",
                    values
                        .iter()
                        .map(|v| AskOption {
                            value: v.clone(),
                            label: v.clone(),
                        })
                        .collect(),
                )
            } else {
                ("text", Vec::new())
            };
            AskQuestion {
                id: id.to_string(),
                prompt: s.title.clone().unwrap_or_else(|| id.to_string()),
                description: s.description.clone(),
                field_type: field_type.to_string(),
                options,
                required,
            }
        }
        ElicitationPropertySchema::Integer(s) => AskQuestion {
            id: id.to_string(),
            prompt: s.title.clone().unwrap_or_else(|| id.to_string()),
            description: s.description.clone(),
            field_type: "number".to_string(),
            options: Vec::new(),
            required,
        },
        ElicitationPropertySchema::Number(s) => AskQuestion {
            id: id.to_string(),
            prompt: s.title.clone().unwrap_or_else(|| id.to_string()),
            description: s.description.clone(),
            field_type: "number".to_string(),
            options: Vec::new(),
            required,
        },
        ElicitationPropertySchema::Boolean(s) => AskQuestion {
            id: id.to_string(),
            prompt: s.title.clone().unwrap_or_else(|| id.to_string()),
            description: s.description.clone(),
            field_type: "boolean".to_string(),
            options: Vec::new(),
            required,
        },
        ElicitationPropertySchema::Array(a) => {
            let options = match &a.items {
                MultiSelectItems::String(s) => s
                    .values
                    .iter()
                    .map(|v| AskOption {
                        value: v.clone(),
                        label: v.clone(),
                    })
                    .collect(),
                MultiSelectItems::Titled(t) => options_from_enum(&t.options),
                _ => Vec::new(),
            };
            AskQuestion {
                id: id.to_string(),
                prompt: a.title.clone().unwrap_or_else(|| id.to_string()),
                description: a.description.clone(),
                field_type: "multi_select".to_string(),
                options,
                required,
            }
        }
        _ => AskQuestion {
            id: id.to_string(),
            prompt: id.to_string(),
            description: None,
            field_type: "text".to_string(),
            options: Vec::new(),
            required,
        },
    }
}

fn options_from_enum(options: &[EnumOption]) -> Vec<AskOption> {
    options
        .iter()
        .map(|o| AskOption {
            value: o.value.clone(),
            label: o.title.clone(),
        })
        .collect()
}

/// Convert a frontend answers map into ACP elicitation content values.
pub fn to_acp_content(
    questions: &[AskQuestion],
    answers: &HashMap<String, serde_json::Value>,
) -> BTreeMap<String, ElicitationContentValue> {
    let mut out = BTreeMap::new();
    for q in questions {
        if let Some(value) = answers.get(&q.id) {
            if let Some(v) = value_to_acp(value, &q.field_type) {
                out.insert(q.id.clone(), v);
            }
        }
    }
    out
}

fn value_to_acp(value: &serde_json::Value, field_type: &str) -> Option<ElicitationContentValue> {
    match field_type {
        "text" | "single_select" => match value {
            serde_json::Value::String(s) => Some(ElicitationContentValue::String(s.clone())),
            _ => Some(ElicitationContentValue::String(value.to_string())),
        },
        "number" => match value {
            serde_json::Value::Number(n) if n.is_i64() => {
                Some(ElicitationContentValue::Integer(n.as_i64().unwrap()))
            }
            serde_json::Value::Number(n) => {
                Some(ElicitationContentValue::Number(n.as_f64().unwrap_or(0.0)))
            }
            serde_json::Value::String(s) => s
                .parse::<i64>()
                .ok()
                .map(ElicitationContentValue::Integer)
                .or_else(|| s.parse::<f64>().ok().map(ElicitationContentValue::Number)),
            _ => None,
        },
        "boolean" => match value {
            serde_json::Value::Bool(b) => Some(ElicitationContentValue::Boolean(*b)),
            serde_json::Value::String(s) if s == "true" => {
                Some(ElicitationContentValue::Boolean(true))
            }
            serde_json::Value::String(s) if s == "false" => {
                Some(ElicitationContentValue::Boolean(false))
            }
            _ => None,
        },
        "multi_select" => match value {
            serde_json::Value::Array(arr) => {
                let strings: Vec<String> = arr
                    .iter()
                    .map(|v| match v {
                        serde_json::Value::String(s) => s.clone(),
                        _ => v.to_string(),
                    })
                    .collect();
                if !strings.is_empty() {
                    Some(ElicitationContentValue::StringArray(strings))
                } else {
                    None
                }
            }
            serde_json::Value::String(s) => {
                Some(ElicitationContentValue::StringArray(vec![s.clone()]))
            }
            _ => None,
        },
        _ => Some(ElicitationContentValue::String(value.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;
    use agent_client_protocol::schema::v1::{
        CreateElicitationRequest, ElicitationContentValue, ElicitationFormMode, ElicitationId,
        ElicitationMode, ElicitationSchema, ElicitationScope, ElicitationSessionScope,
        ElicitationUrlMode, EnumOption, MultiSelectPropertySchema, SessionId, StringPropertySchema,
    };

    fn form_request(schema: ElicitationSchema) -> CreateElicitationRequest {
        CreateElicitationRequest::new(
            ElicitationMode::Form(ElicitationFormMode::new(
                ElicitationScope::Session(ElicitationSessionScope::new(SessionId::new("sess"))),
                schema,
            )),
            "Please fill this out",
        )
    }

    #[test]
    fn from_acp_maps_all_question_types() {
        let schema = ElicitationSchema::new()
            .title("survey")
            .description("a survey")
            .string("name", true)
            .number("age", 0.0, 150.0, false)
            .boolean("subscribe", false)
            .property(
                "color",
                StringPropertySchema::new()
                    .title("Pick a color")
                    .one_of(vec![
                        EnumOption::new("red", "Red"),
                        EnumOption::new("blue", "Blue"),
                    ]),
                false,
            )
            .property(
                "tags",
                MultiSelectPropertySchema::titled(vec![
                    EnumOption::new("x", "X"),
                    EnumOption::new("y", "Y"),
                ]),
                true,
            );

        let req = form_request(schema);
        let ask = from_acp(&req).expect("form should parse");

        assert_eq!(ask.message, "Please fill this out");
        assert_eq!(ask.questions.len(), 5);

        let by_id: HashMap<_, _> = ask.questions.iter().map(|q| (q.id.clone(), q)).collect();

        assert_eq!(by_id["name"].field_type, "text");
        assert!(by_id["name"].required);
        assert_eq!(by_id["name"].prompt, "name");

        assert_eq!(by_id["age"].field_type, "number");
        assert!(!by_id["age"].required);

        assert_eq!(by_id["subscribe"].field_type, "boolean");

        assert_eq!(by_id["color"].field_type, "single_select");
        assert_eq!(by_id["color"].options.len(), 2);
        assert_eq!(by_id["color"].options[0].label, "Red");

        assert_eq!(by_id["tags"].field_type, "multi_select");
        assert!(by_id["tags"].required);
    }

    #[test]
    fn from_acp_skips_unsupported_modes() {
        let url = CreateElicitationRequest::new(
            ElicitationMode::Url(ElicitationUrlMode::new(
                ElicitationScope::Session(ElicitationSessionScope::new(SessionId::new("sess"))),
                ElicitationId::new("url"),
                "https://example.com".to_string(),
            )),
            "Visit this URL",
        );
        assert!(from_acp(&url).is_none());
    }

    #[test]
    fn from_acp_returns_none_for_empty_schema() {
        let req = form_request(ElicitationSchema::new());
        assert!(from_acp(&req).is_none());
    }

    #[test]
    fn to_acp_content_converts_text_number_boolean_and_selects() {
        let questions = vec![
            AskQuestion {
                id: "name".to_string(),
                prompt: "Name".to_string(),
                description: None,
                field_type: "text".to_string(),
                options: vec![],
                required: true,
            },
            AskQuestion {
                id: "age".to_string(),
                prompt: "Age".to_string(),
                description: None,
                field_type: "number".to_string(),
                options: vec![],
                required: false,
            },
            AskQuestion {
                id: "active".to_string(),
                prompt: "Active".to_string(),
                description: None,
                field_type: "boolean".to_string(),
                options: vec![],
                required: false,
            },
            AskQuestion {
                id: "color".to_string(),
                prompt: "Color".to_string(),
                description: None,
                field_type: "single_select".to_string(),
                options: vec![],
                required: false,
            },
            AskQuestion {
                id: "tags".to_string(),
                prompt: "Tags".to_string(),
                description: None,
                field_type: "multi_select".to_string(),
                options: vec![],
                required: false,
            },
        ];

        let mut answers = HashMap::new();
        answers.insert("name".to_string(), serde_json::json!("Alice"));
        answers.insert("age".to_string(), serde_json::json!(42));
        answers.insert("active".to_string(), serde_json::json!(true));
        answers.insert("color".to_string(), serde_json::json!("blue"));
        answers.insert("tags".to_string(), serde_json::json!(["x", "y"]));

        let content = to_acp_content(&questions, &answers);

        assert_eq!(
            content.get("name"),
            Some(&ElicitationContentValue::String("Alice".to_string()))
        );
        assert_eq!(
            content.get("age"),
            Some(&ElicitationContentValue::Integer(42))
        );
        assert_eq!(
            content.get("active"),
            Some(&ElicitationContentValue::Boolean(true))
        );
        assert_eq!(
            content.get("color"),
            Some(&ElicitationContentValue::String("blue".to_string()))
        );
        assert_eq!(
            content.get("tags"),
            Some(&ElicitationContentValue::StringArray(vec!["x".to_string(), "y".to_string()]))
        );
    }

    #[test]
    fn to_acp_content_skips_missing_answers() {
        let q = AskQuestion {
            id: "name".to_string(),
            prompt: "Name".to_string(),
            description: None,
            field_type: "text".to_string(),
            options: vec![],
            required: true,
        };
        let content = to_acp_content(&[q], &HashMap::new());
        assert!(content.is_empty());
    }

    #[test]
    fn to_acp_content_parses_number_from_string() {
        let q = AskQuestion {
            id: "n".to_string(),
            prompt: "N".to_string(),
            description: None,
            field_type: "number".to_string(),
            options: vec![],
            required: false,
        };
        let mut answers = HashMap::new();
        answers.insert("n".to_string(), serde_json::json!("3.14"));
        let content = to_acp_content(&[q], &answers);
        assert_eq!(
            content.get("n"),
            Some(&ElicitationContentValue::Number(3.14))
        );
    }
}
