use crate::runtime::{Control, ExtensionServices};
use rquickjs::{Ctx, Function, Object};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use zeroize::Zeroizing;

pub(crate) fn register<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<()> {
    host.set("sessionEnabled", services.session.is_some())?;
    if let Some(session) = &services.session {
        let session = Arc::clone(session);
        host.set(
            "sessionCall",
            Function::new(ctx.clone(), move |method: String, arguments: String| {
                let arguments = Zeroizing::new(arguments);
                let check = || control.check().map_err(|error| error.to_string());
                let result = (|| {
                    check()?;
                    let args: Vec<Value> =
                        serde_json::from_str(&arguments).map_err(|error| error.to_string())?;
                    let string = |index| args.get(index).and_then(Value::as_str).unwrap_or("");
                    match method.as_str() {
                        "status" => session.status(),
                        "clear" => session.clear().map(|()| json!({"success":true})),
                        "completeGrant" => session
                            .complete_grant(string(0), check)
                            .map(|()| json!({"success":true})),
                        "signedFetch" => {
                            if args.len() < 2 {
                                return Err("method and path are required".into());
                            }
                            let headers: BTreeMap<String, String> = args
                                .get(3)
                                .cloned()
                                .map(serde_json::from_value)
                                .transpose()
                                .map_err(|error| error.to_string())?
                                .unwrap_or_default();
                            session.signed_fetch(string(0), string(1), string(2), &headers, check)
                        }
                        _ => Err("unknown signed session method".into()),
                    }
                })();
                match result {
                    Ok(value) => value,
                    Err(error) if method == "status" => {
                        json!({"authenticated":false,"error":error})
                    }
                    Err(error) if method == "signedFetch" => json!({"ok":false,"error":error}),
                    Err(error) => json!({"success":false,"error":error}),
                }
                .to_string()
            })?,
        )?;
    }
    Ok(())
}
