use serde::de::DeserializeOwned;
use serde::Serialize;
use wasm_bindgen::JsCast;
use wasm_bindgen::JsValue;
use web_sys::{FormData, Headers, Request as WebRequest, RequestInit, Response as WebResponse};

use crate::types::ApiError;

/// Generic JSON API call. Returns deserialized response or an error message.
pub async fn api_get<T: DeserializeOwned>(path: &str) -> Result<T, String> {
    api_request("GET", path, None::<String>).await
}

pub async fn api_post<T: DeserializeOwned, B: Serialize>(
    path: &str,
    body: &B,
) -> Result<T, String> {
    let json = serde_json::to_string(body).map_err(|e| e.to_string())?;
    api_request("POST", path, Some(json)).await
}

pub async fn api_patch<T: DeserializeOwned, B: Serialize>(
    path: &str,
    body: &B,
) -> Result<T, String> {
    let json = serde_json::to_string(body).map_err(|e| e.to_string())?;
    api_request("PATCH", path, Some(json)).await
}

pub async fn api_delete<T: DeserializeOwned>(path: &str) -> Result<T, String> {
    api_request("DELETE", path, None::<String>).await
}

pub async fn api_post_form<T: DeserializeOwned>(
    path: &str,
    form: FormData,
) -> Result<T, String> {
    let opts = RequestInit::new();
    opts.set_method("POST");
    opts.set_body(&form);
    let request = WebRequest::new_with_str_and_init(path, &opts)
        .map_err(|e| format!("request error: {:?}", e))?;
    do_fetch(request).await
}

async fn api_request<T: DeserializeOwned>(
    method: &str,
    path: &str,
    body: Option<String>,
) -> Result<T, String> {
    let opts = RequestInit::new();
    opts.set_method(method);

    if let Some(ref json) = body {
        let headers = Headers::new().map_err(|e| format!("headers error: {:?}", e))?;
        headers
            .append("content-type", "application/json")
            .map_err(|e| format!("headers error: {:?}", e))?;
        opts.set_headers(&headers);
        opts.set_body(&JsValue::from_str(json));
    }

    let request = WebRequest::new_with_str_and_init(path, &opts)
        .map_err(|e| format!("request error: {:?}", e))?;

    do_fetch(request).await
}

async fn do_fetch<T: DeserializeOwned>(request: WebRequest) -> Result<T, String> {
    let window = web_sys::window().ok_or("no window")?;
    let resp_val = wasm_bindgen_futures::JsFuture::from(window.fetch_with_request(&request))
        .await
        .map_err(|e| format!("fetch error: {:?}", e))?;
    let resp: WebResponse = resp_val.dyn_into().map_err(|e| format!("response error: {:?}", e))?;

    let status = resp.status();
    let text = wasm_bindgen_futures::JsFuture::from(resp.text().map_err(|e| format!("text error: {:?}", e))?)
        .await
        .map_err(|e| format!("text error: {:?}", e))?
        .as_string()
        .unwrap_or_default();

    if status < 200 || status >= 300 {
        let msg = if !text.is_empty() {
            match serde_json::from_str::<ApiError>(&text) {
                Ok(e) => e.error,
                Err(_) => text,
            }
        } else {
            format!("HTTP {}", status)
        };
        return Err(msg);
    }

    if text.is_empty() {
        return serde_json::from_str("null").map_err(|e| e.to_string());
    }

    serde_json::from_str(&text).map_err(|e| format!("parse error: {} (text: {})", e, &text[..text.len().min(200)]))
}

/// Upload files via multipart form data.
pub async fn upload_files(path: &str, files_path: &str, files: &[web_sys::File]) -> Result<(), String> {
    let form = FormData::new().map_err(|e| format!("form error: {:?}", e))?;
    form.append_with_str("path", files_path)
        .map_err(|e| format!("form error: {:?}", e))?;
    for file in files {
        form.append_with_blob_and_filename("file", file, &file.name())
            .map_err(|e| format!("form error: {:?}", e))?;
    }
    api_post_form::<serde_json::Value>(path, form).await?;
    Ok(())
}

/// Send a message with optional file attachments.
pub async fn send_message(
    path: &str,
    prompt: &str,
    files: &[web_sys::File],
) -> Result<crate::types::SendResponse, String> {
    let form = FormData::new().map_err(|e| format!("form error: {:?}", e))?;
    form.append_with_str("prompt", prompt)
        .map_err(|e| format!("form error: {:?}", e))?;
    for file in files {
        form.append_with_blob_and_filename("file", file, &file.name())
            .map_err(|e| format!("form error: {:?}", e))?;
    }
    api_post_form(path, form).await
}
