use crate::host::decode_go_utf8;
use rquickjs::{Ctx, Function, IntoJs, Object, Value};
use spotiflac_network::{
    query,
    url::{UrlParts, unescape_path},
};
use std::{cell::RefCell, rc::Rc};

pub(crate) fn register<'js>(ctx: &Ctx<'js>, host: &Object<'js>) -> rquickjs::Result<()> {
    host.set("parseURL", Function::new(ctx.clone(), parse_url)?)?;
    host.set("parseQuery", Function::new(ctx.clone(), query_object)?)?;
    Ok(())
}

fn parse_url<'js>(
    ctx: Ctx<'js>,
    input: String,
    base: Option<String>,
) -> rquickjs::Result<Object<'js>> {
    let object = Object::new(ctx.clone())?;
    let parsed = base
        .as_deref()
        .and_then(UrlParts::parse)
        .and_then(|base| base.resolve_reference(&input))
        .or_else(|| UrlParts::parse(&input));
    let Some(parsed) = parsed else {
        object.set("href", input)?;
        return Ok(object);
    };
    object.set("href", parsed.reference_string())?;
    object.set("protocol", format!("{}:", parsed.scheme))?;
    object.set("host", decode_go_utf8(&parsed.host))?;
    let host_end = parsed.host.len() - parsed.port.as_ref().map_or(0, |port| port.len() + 1);
    let hostname = &parsed.host[..host_end];
    let hostname = hostname
        .strip_prefix(b"[")
        .and_then(|host| host.strip_suffix(b"]"))
        .unwrap_or(hostname);
    object.set("hostname", decode_go_utf8(hostname))?;
    object.set("port", parsed.port.as_deref().unwrap_or_default())?;
    object.set(
        "pathname",
        if parsed.raw_path.is_empty() {
            String::new()
        } else {
            decode_go_utf8(&parsed.path)
        },
    )?;
    object.set(
        "search",
        if parsed.raw_query.is_empty() {
            String::new()
        } else {
            format!("?{}", parsed.raw_query)
        },
    )?;
    let fragment = decode_go_utf8(&unescape_path(&parsed.fragment).unwrap_or_default());
    object.set(
        "hash",
        if fragment.is_empty() {
            String::new()
        } else {
            format!("#{fragment}")
        },
    )?;
    object.set(
        "origin",
        format!("{}://{}", parsed.scheme, decode_go_utf8(&parsed.host)),
    )?;
    object.set("username", decode_go_utf8(&parsed.username))?;
    object.set(
        "password",
        decode_go_utf8(parsed.password.as_deref().unwrap_or_default()),
    )?;
    object.set("searchParams", query_object(ctx, parsed.raw_query)?)?;
    Ok(object)
}

fn query_object<'js>(ctx: Ctx<'js>, input: String) -> rquickjs::Result<Object<'js>> {
    let object = Object::new(ctx.clone())?;
    let values = Rc::new(RefCell::new(query::parse(&input)));
    let read = Rc::clone(&values);
    object.set(
        "read",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, method: String, key: String| {
                let values = read.borrow();
                let found = values.get(key.as_bytes());
                match method.as_str() {
                    "has" => found.is_some().into_js(&ctx),
                    "getAll" => match found {
                        Some(values) => values
                            .iter()
                            .map(|value| decode_go_utf8(value))
                            .collect::<Vec<_>>()
                            .into_js(&ctx),
                        None => Ok(Value::new_null(ctx)),
                    },
                    _ => match found
                        .and_then(|values| values.first())
                        .filter(|value| !value.is_empty())
                    {
                        Some(value) => decode_go_utf8(value).into_js(&ctx),
                        None => Ok(Value::new_null(ctx)),
                    },
                }
            },
        )?,
    )?;
    let write = Rc::clone(&values);
    object.set(
        "write",
        Function::new(
            ctx.clone(),
            move |method: String, key: String, value: String| {
                let mut values = write.borrow_mut();
                match method.as_str() {
                    "append" => values
                        .entry(key.into_bytes())
                        .or_default()
                        .push(value.into_bytes()),
                    "set" => query::set(&mut values, &key, &value),
                    _ => {
                        values.remove(key.as_bytes());
                    }
                }
            },
        )?,
    )?;
    object.set(
        "encode",
        Function::new(ctx, move || query::encode(&values.borrow()))?,
    )?;
    Ok(object)
}

#[cfg(test)]
mod tests {
    use crate::{ExtensionRuntime, RuntimeLimits};
    use serde_json::json;

    #[test]
    fn url_globals_resolve_track_paths_and_album_query_ids() {
        let runtime = ExtensionRuntime::load(
            r#"
            registerExtension({probe() {
                return [typeof URL, typeof URLSearchParams, ...[
                    "https://music.example.test/tracks/TRACK123/",
                    "https://music.example.test/albums/ALBUM123?trackAsin=TRACK456",
                    "https://music.example.test/artists/ARTIST123"
                ].map(link => {
                    try {
                        const url = new URL(link);
                        if (url.hostname !== "music.example.test") return null;
                        const track = url.searchParams.get("trackAsin");
                        if (track) return track;
                        const match = url.pathname.match(/^\/tracks\/([^/]+)/);
                        return match ? match[1] : null;
                    } catch (_) { return null; }
                })];
            }});
        "#,
            "{}",
            RuntimeLimits::default(),
        )
        .unwrap();
        let result: serde_json::Value =
            serde_json::from_str(&runtime.call("probe", "[]", None, 1000).unwrap()).unwrap();
        assert_eq!(
            result,
            json!(["function", "function", "TRACK123", "TRACK456", null])
        );
    }

    #[test]
    fn url_and_query_objects_preserve_legacy_constructor_contracts() {
        let runtime = ExtensionRuntime::load(r#"
            registerExtension({probe() {
                const url = new URL("../a%2Fb?z=2&z=3&empty&bad=%Q&semi=a;b#hi%20there", "https://u:p@EXAMPLE.test:443/x/y");
                const original = url.toString();
                url.href = "changed";
                const params = new URLSearchParams("?z=first&empty=&z=second&raw=%FF&bad=%Q&semi=a;b");
                const before = [params.get("z"), params.getAll("z"), params.get("empty"), params.has("empty"), params.getAll("missing"), params.getAll(), params.toString()];
                params.append("z", "last"); params.set("empty", "a b"); params.delete("raw"); params.set("ignored");
                const object = new URLSearchParams({z: [1, 2], nil: null, ok: true});
                return [original, url.protocol, url.host, url.hostname, url.port, url.pathname, url.search, url.hash, url.origin, url.username, url.password,
                    url.toString(), JSON.stringify(url), url.searchParams.toString(), typeof url.searchParams.set,
                    before, params.toString(), object.toString(),
                    Object.keys(new URL()), Object.keys(new URL("http://[bad]")),
                    new URL("https://example.test?").toString(), new URL("mailto:a@example.test").toString(),
                    new URL("/a", "broken base").toString(), new URL("https://[fe80::1%25en0]:80/a").host,
                    Object.keys(params), new URLSearchParams(new String("?x=y")).toString(),
                    new URL("https://%FF%E0%A4.test/").hostname,
                    new URLSearchParams("x=\ud800&\udfff=v").toString()];
            }});
        "#, "{}", RuntimeLimits::default()).unwrap();
        let result: serde_json::Value =
            serde_json::from_str(&runtime.call("probe", "[]", None, 1000).unwrap()).unwrap();
        let href = "https://u:p@EXAMPLE.test:443/a%2Fb?z=2&z=3&empty&bad=%Q&semi=a;b#hi%20there";
        assert_eq!(
            result,
            json!([
                href,
                "https:",
                "EXAMPLE.test:443",
                "EXAMPLE.test",
                "443",
                "/a/b",
                "?z=2&z=3&empty&bad=%Q&semi=a;b",
                "#hi there",
                "https://EXAMPLE.test:443",
                "u",
                "p",
                href,
                serde_json::to_string(href).unwrap(),
                "empty=&z=2&z=3",
                "undefined",
                [
                    "first",
                    ["first", "second"],
                    null,
                    true,
                    null,
                    [],
                    "empty=&raw=%FF&z=first&z=second"
                ],
                "empty=a+b&z=first&z=second&z=last",
                "nil=%3Cnil%3E&ok=true&z=%5B1+2%5D",
                ["href"],
                ["href"],
                "https://example.test?",
                "mailto:a@example.test",
                "/a",
                "[fe80::1%en0]:80",
                [
                    "append", "delete", "get", "getAll", "has", "set", "toString"
                ],
                "",
                "���.test",
                "x=%EF%BF%BD&%EF%BF%BD=v"
            ])
        );
    }
}
