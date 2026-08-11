use serde::de::DeserializeOwned;
use serde::Serialize;
use wasm_bindgen::JsCast;
use wasm_bindgen::JsValue;
use web_sys::{FormData, Headers, ReadableStreamDefaultReader, Request as WebRequest, RequestInit, Response as WebResponse};

use crate::types::{ApiError, Message};

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



/// Stream a message response as Server-Sent Events.
pub async fn send_message_stream<F>(
    path: &str,
    prompt: &str,
    files: &[web_sys::File],
    mut on_user_message: F,
    mut on_chunk: impl FnMut(&str),
    mut on_done: impl FnMut(Message),
    mut on_error: impl FnMut(&str),
) -> Result<(), String>
where
    F: FnMut(Message),
{
    let form = FormData::new().map_err(|e| format!("form error: {:?}", e))?;
    form.append_with_str("prompt", prompt)
        .map_err(|e| format!("form error: {:?}", e))?;
    for file in files {
        form.append_with_blob_and_filename("file", file, &file.name())
            .map_err(|e| format!("form error: {:?}", e))?;
    }

    let opts = RequestInit::new();
    opts.set_method("POST");
    opts.set_body(&form);

    let request = WebRequest::new_with_str_and_init(path, &opts)
        .map_err(|e| format!("request error: {:?}", e))?;

    let window = web_sys::window().ok_or("no window")?;
    let resp_val = wasm_bindgen_futures::JsFuture::from(window.fetch_with_request(&request))
        .await
        .map_err(|e| format!("fetch error: {:?}", e))?;
    let resp: WebResponse = resp_val.dyn_into().map_err(|e| format!("response cast error: {:?}", e))?;

    if resp.status() >= 400 {
        let text = wasm_bindgen_futures::JsFuture::from(resp.text().map_err(|e| format!("text error: {:?}", e))?)
            .await
            .map_err(|e| format!("text error: {:?}", e))?
            .as_string()
            .unwrap_or_default();
        return if let Ok(err) = serde_json::from_str::<ApiError>(&text) {
            Err(err.error)
        } else {
            Err(format!("HTTP {}: {}", resp.status(), text))
        };
    }

    let body = resp.body().ok_or("no response body")?;
    let reader: ReadableStreamDefaultReader = body
        .get_reader()
        .dyn_into()
        .map_err(|e| format!("reader error: {:?}", e))?;

    let mut buffer = String::new();
    loop {
        let result = wasm_bindgen_futures::JsFuture::from(reader.read())
            .await
            .map_err(|e| format!("read error: {:?}", e))?;
        let obj: js_sys::Object = result.dyn_into().map_err(|e| format!("read result error: {:?}", e))?;
        let done = js_sys::Reflect::get(&obj, &"done".into())
            .map_err(|_| "no done field")?
            .as_bool()
            .unwrap_or(false);
        if done {
            break;
        }
        let value = js_sys::Reflect::get(&obj, &"value".into()).map_err(|_| "no value field")?;
        let arr = js_sys::Uint8Array::from(value);
        let chunk = String::from_utf8_lossy(&arr.to_vec()).into_owned();
        buffer.push_str(&chunk);

        while let Some(pos) = buffer.find("\n\n") {
            let block = buffer[..pos].to_string();
            buffer.replace_range(..pos + 2, "");
            parse_sse_block(&block, &mut on_user_message, &mut on_chunk, &mut on_done, &mut on_error);
        }
    }

    // Process any final block without a trailing blank line.
    if !buffer.trim().is_empty() {
        parse_sse_block(&buffer, &mut on_user_message, &mut on_chunk, &mut on_done, &mut on_error);
    }

    Ok(())
}

fn parse_sse_block(
    block: &str,
    on_user_message: &mut impl FnMut(Message),
    on_chunk: &mut impl FnMut(&str),
    on_done: &mut impl FnMut(Message),
    on_error: &mut impl FnMut(&str),
) {
    let mut event = String::new();
    let mut data_lines: Vec<&str> = Vec::new();

    for line in block.lines() {
        if let Some(stripped) = line.strip_prefix("event:") {
            event = stripped.trim().to_string();
        } else if let Some(stripped) = line.strip_prefix("data:") {
            // SSE spec: a single space after the colon is part of the
            // field-name/value separator and not the value itself.
            data_lines.push(stripped.strip_prefix(' ').unwrap_or(stripped));
        }
    }

    let data = data_lines.join("\n");
    match event.as_str() {
        "user_message" => {
            if let Ok(msg) = serde_json::from_str::<Message>(&data) {
                on_user_message(msg);
            }
        }
        "chunk" => on_chunk(&data),
        "done" => {
            if let Ok(msg) = serde_json::from_str::<Message>(&data) {
                on_done(msg);
            }
        }
        "error" => on_error(&data),
        _ => {}
    }
}
