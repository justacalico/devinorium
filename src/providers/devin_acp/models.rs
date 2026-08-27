use once_cell::sync::Lazy;

use crate::providers::ModelInfo;

pub fn static_models() -> Vec<ModelInfo> {
    vec![
        ModelInfo {
            id: "glm-5-2".into(),
            label: "GLM-5.2 High".into(),
            cost_tier: "low".into(),
            family: "glm".into(),
            cost_summary: "Free".into(),
            max_context_tokens: 1_000_000,
            max_output_tokens: 128_000,
            is_new: false,
            is_beta: false,
        },
        ModelInfo {
            id: "claude-opus-5-medium".into(),
            label: "Claude Opus 5 Medium".into(),
            cost_tier: "high".into(),
            family: "claude".into(),
            cost_summary: "$5 / MTok In · $25 / MTok Out".into(),
            max_context_tokens: 1_000_000,
            max_output_tokens: 128_000,
            is_new: false,
            is_beta: false,
        },
    ]
}

pub static MODELS: Lazy<Vec<ModelInfo>> = Lazy::new(static_models);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn static_models_includes_known_entries() {
        let models = static_models();
        assert_eq!(models.len(), 2);
        assert!(models.iter().any(|m| m.id == "glm-5-2"));
        assert!(models.iter().any(|m| m.id == "claude-opus-5-medium"));
    }

    #[test]
    fn models_lazy_static_matches_static_models() {
        assert_eq!(MODELS.len(), static_models().len());
        assert_eq!(MODELS[0].id, "glm-5-2");
    }
}
