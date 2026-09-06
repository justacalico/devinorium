use agent_client_protocol::schema::v1::{
    CreateElicitationRequest, CreateElicitationResponse, ElicitationAcceptAction, ElicitationAction,
};

use crate::providers::{ask, AskCallback, AskOutcome};

pub(crate) async fn handle_ask_request(
    request: CreateElicitationRequest,
    ask_callback: Option<&AskCallback>,
) -> CreateElicitationResponse {
    let ask_request = match ask::from_acp(&request) {
        Some(req) => req,
        None => {
            tracing::warn!("unsupported elicitation mode; declining");
            return CreateElicitationResponse::new(ElicitationAction::Decline);
        }
    };

    let Some(callback) = ask_callback else {
        tracing::warn!("no ask callback configured; cancelling elicitation request");
        return CreateElicitationResponse::new(ElicitationAction::Cancel);
    };

    tracing::info!(
        request_id = %ask_request.request_id,
        questions = ask_request.questions.len(),
        "forwarding acp elicitation request"
    );

    match callback(ask_request.clone()).await {
        AskOutcome::Answers(answers) => {
            let content = ask::to_acp_content(&ask_request.questions, &answers);
            CreateElicitationResponse::new(ElicitationAcceptAction::new().content(content))
        }
        AskOutcome::Cancel => CreateElicitationResponse::new(ElicitationAction::Cancel),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::future::Future;
    use std::pin::Pin;
    use std::sync::Arc;

    use agent_client_protocol::schema::v1::{
        CreateElicitationRequest, ElicitationFormMode, ElicitationId, ElicitationMode,
        ElicitationSchema, ElicitationScope, ElicitationSessionScope, SessionId,
    };

    use crate::providers::AskRequest;

    fn form_request(schema: ElicitationSchema) -> CreateElicitationRequest {
        CreateElicitationRequest::new(
            ElicitationMode::Form(ElicitationFormMode::new(
                ElicitationScope::Session(ElicitationSessionScope::new(SessionId::new("sess"))),
                schema,
            )),
            "Please fill this out",
        )
    }

    #[tokio::test]
    async fn handle_ask_request_cancels_without_callback() {
        let schema = ElicitationSchema::new().string("name", true);
        let request = form_request(schema);

        let response = handle_ask_request(request, None).await;
        assert_eq!(response.action, ElicitationAction::Cancel);
    }

    #[tokio::test]
    async fn handle_ask_request_returns_answers() {
        let schema = ElicitationSchema::new().string("name", true);
        let request = form_request(schema);

        let callback: AskCallback = Arc::new(|_req: AskRequest| {
            Box::pin(async move {
                let mut answers = HashMap::new();
                answers.insert("name".to_string(), serde_json::json!("Alice"));
                AskOutcome::Answers(answers)
            }) as Pin<Box<dyn Future<Output = AskOutcome> + Send>>
        });

        let response = handle_ask_request(request, Some(&callback)).await;
        assert!(matches!(response.action, ElicitationAction::Accept(_)));
    }

    #[tokio::test]
    async fn handle_ask_request_declines_unsupported_mode() {
        let request = CreateElicitationRequest::new(
            ElicitationMode::Url(agent_client_protocol::schema::v1::ElicitationUrlMode::new(
                ElicitationScope::Session(ElicitationSessionScope::new(SessionId::new("sess"))),
                ElicitationId::new("url"),
                "https://example.com".to_string(),
            )),
            "Visit this URL",
        );

        let response = handle_ask_request(request, None).await;
        assert_eq!(response.action, ElicitationAction::Decline);
    }
}
