//! Marshall's Cedar engine: one compiled, schema-validated policy set evaluated
//! from typed Erlang terms, with type-aware partial evaluation for read filters.
//!
//! Terms crossing the boundary:
//! - entity: `{type, id, attrs, parents}` where `attrs` is a list of
//!   `{name, value}` and `parents` a list of `{type, id}`.
//! - value: `true | false`, an integer, a binary string, an entity reference
//!   `{type, id}`, or a list (a Cedar set) of values.
//!
//! Entity type names are unqualified (`"User"`); the `Marshall::` namespace is
//! applied here so callers cannot address another namespace.

use cedar_policy::{
    Authorizer, Context, Decision, Entities, Entity, EntityId, EntityTypeName, EntityUid,
    PartialEntities, PartialEntityUid, PartialRequest, PolicySet, Request, RequestValidationError,
    RestrictedExpression, Schema, ValidationMode, Validator,
};
use rustler::{Atom, Error, NifResult, Resource, ResourceArc, Term, TermType};
use std::collections::{HashMap, HashSet};
use std::str::FromStr;

mod atoms {
    rustler::atoms! { allow, deny, residual }
}

const NAMESPACE: &str = "Marshall::";

pub struct Engine {
    policies: PolicySet,
    schema: Schema,
}

impl std::fmt::Debug for Engine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Engine").finish_non_exhaustive()
    }
}

#[rustler::resource_impl]
impl Resource for Engine {}

type Reference = (String, String);
type EntityTerm<'a> = (String, String, Vec<(String, Term<'a>)>, Vec<Reference>);

fn type_name(ty: &str) -> Result<EntityTypeName, String> {
    EntityTypeName::from_str(&format!("{NAMESPACE}{ty}")).map_err(|e| e.to_string())
}

fn uid((ty, id): &Reference) -> Result<EntityUid, String> {
    Ok(EntityUid::from_type_name_and_id(
        type_name(ty)?,
        EntityId::new(id),
    ))
}

fn action_uid(action: &str) -> Result<EntityUid, String> {
    uid(&("Action".to_owned(), action.to_owned()))
}

fn value(term: Term<'_>) -> Result<RestrictedExpression, String> {
    match term.get_type() {
        TermType::Atom => term
            .decode::<bool>()
            .map(RestrictedExpression::new_bool)
            .map_err(|_| "unsupported atom value".to_owned()),
        TermType::Integer => term
            .decode::<i64>()
            .map(RestrictedExpression::new_long)
            .map_err(|_| "integer out of range".to_owned()),
        TermType::Binary => term
            .decode::<String>()
            .map(RestrictedExpression::new_string)
            .map_err(|_| "invalid string value".to_owned()),
        TermType::Tuple => {
            let reference: Reference = term
                .decode()
                .map_err(|_| "entity reference must be {type, id}".to_owned())?;
            uid(&reference).map(RestrictedExpression::new_entity_uid)
        }
        TermType::List => {
            let items: Vec<Term<'_>> = term.decode().map_err(|_| "invalid set".to_owned())?;
            items
                .into_iter()
                .map(value)
                .collect::<Result<Vec<_>, _>>()
                .map(RestrictedExpression::new_set)
        }
        _ => Err("unsupported attribute value".to_owned()),
    }
}

fn entity((ty, id, attrs, parents): EntityTerm<'_>) -> Result<Entity, String> {
    let attrs = attrs
        .into_iter()
        .map(|(name, term)| value(term).map(|v| (name, v)))
        .collect::<Result<HashMap<_, _>, _>>()?;
    let parents = parents.iter().map(uid).collect::<Result<HashSet<_>, _>>()?;
    Entity::new(uid(&(ty, id))?, attrs, parents).map_err(|e| e.to_string())
}

fn entities(engine: &Engine, terms: Vec<EntityTerm<'_>>) -> Result<Entities, String> {
    let list = terms
        .into_iter()
        .map(entity)
        .collect::<Result<Vec<_>, _>>()?;
    Entities::from_entities(list, Some(&engine.schema)).map_err(|e| e.to_string())
}

fn raise(message: String) -> Error {
    Error::RaiseTerm(Box::new(message))
}

/// Compiles the policy set and schema and requires strict validation with no
/// errors and no warnings; anything else returns the findings and no engine.
#[allow(
    clippy::needless_pass_by_value,
    reason = "Rustler decodes NIF arguments into owned values"
)]
#[rustler::nif(schedule = "DirtyCpu")]
fn compile(policy_text: String, schema_text: String) -> Result<ResourceArc<Engine>, Vec<String>> {
    let policies = PolicySet::from_str(&policy_text)
        .map_err(|e| e.iter().map(ToString::to_string).collect::<Vec<_>>())?;
    let (schema, warnings) =
        Schema::from_cedarschema_str(&schema_text).map_err(|e| vec![e.to_string()])?;
    let mut findings: Vec<String> = warnings.map(|w| w.to_string()).collect();
    let result = Validator::new(schema.clone()).validate(&policies, ValidationMode::Strict);
    findings.extend(result.validation_errors().map(ToString::to_string));
    findings.extend(result.validation_warnings().map(ToString::to_string));
    if findings.is_empty() {
        Ok(ResourceArc::new(Engine { policies, schema }))
    } else {
        Err(findings)
    }
}

fn decide(
    engine: &Engine,
    entities: &Entities,
    principal: &EntityUid,
    action: &EntityUid,
    resource: &EntityUid,
) -> Result<bool, String> {
    // A declared principal or resource type the action does not apply to can
    // satisfy no schema-validated policy: that is a plain deny, not an error.
    // Undeclared types and actions remain errors.
    let request = match Request::new(
        principal.clone(),
        action.clone(),
        resource.clone(),
        Context::empty(),
        Some(&engine.schema),
    ) {
        Ok(request) => request,
        Err(
            RequestValidationError::InvalidPrincipalType(_)
            | RequestValidationError::InvalidResourceType(_),
        ) => return Ok(false),
        Err(error) => return Err(error.to_string()),
    };
    let response = Authorizer::new().is_authorized(&request, &engine.policies, entities);
    if response.diagnostics().errors().next().is_some() {
        return Err("evaluation error".to_owned());
    }
    Ok(response.decision() == Decision::Allow)
}

/// One decision. `entities` must contain the principal, the resource and any
/// entity their attributes reference that policy reads.
#[allow(
    clippy::needless_pass_by_value,
    reason = "Rustler decodes NIF arguments into owned values"
)]
#[rustler::nif]
fn authorize(
    engine: ResourceArc<Engine>,
    entity_terms: Vec<EntityTerm<'_>>,
    principal: Reference,
    action: String,
    resource: Reference,
) -> NifResult<bool> {
    let entities = entities(&engine, entity_terms).map_err(raise)?;
    decide(
        &engine,
        &entities,
        &uid(&principal).map_err(raise)?,
        &action_uid(&action).map_err(raise)?,
        &uid(&resource).map_err(raise)?,
    )
    .map_err(raise)
}

/// The same principal and action over many resources sharing one entity store;
/// one boundary crossing per page instead of one per row.
#[allow(
    clippy::needless_pass_by_value,
    reason = "Rustler decodes NIF arguments into owned values"
)]
#[rustler::nif(schedule = "DirtyCpu")]
fn authorize_many(
    engine: ResourceArc<Engine>,
    entity_terms: Vec<EntityTerm<'_>>,
    principal: Reference,
    action: String,
    resources: Vec<Reference>,
) -> NifResult<Vec<bool>> {
    let entities = entities(&engine, entity_terms).map_err(raise)?;
    let principal = uid(&principal).map_err(raise)?;
    let action = action_uid(&action).map_err(raise)?;
    resources
        .iter()
        .map(|resource| decide(&engine, &entities, &principal, &action, &uid(resource)?))
        .collect::<Result<Vec<_>, _>>()
        .map_err(raise)
}

/// Type-aware partial evaluation with both principal and resource unknown.
/// Returns `:allow`, `:deny`, or `{:residual, [policy_json]}` where each JSON
/// string is a residual permit or forbid in Cedar's JSON policy format.
#[allow(
    clippy::needless_pass_by_value,
    reason = "Rustler decodes NIF arguments into owned values"
)]
#[rustler::nif(schedule = "DirtyCpu")]
fn residuals(
    engine: ResourceArc<Engine>,
    principal_type: String,
    action: String,
    resource_type: String,
) -> NifResult<(Atom, Vec<String>)> {
    let request = PartialRequest::new(
        PartialEntityUid::new(type_name(&principal_type).map_err(raise)?, None),
        action_uid(&action).map_err(raise)?,
        PartialEntityUid::new(type_name(&resource_type).map_err(raise)?, None),
        Some(Context::empty()),
        &engine.schema,
    )
    .map_err(|e| raise(e.to_string()))?;
    let empty = PartialEntities::empty();
    let response = engine
        .policies
        .tpe(&request, &empty, &engine.schema)
        .map_err(|e| raise(e.to_string()))?;
    match response.decision() {
        Some(Decision::Allow) => Ok((atoms::allow(), vec![])),
        Some(Decision::Deny) => Ok((atoms::deny(), vec![])),
        None => response
            .residual_policies()
            .map(|policy| {
                policy
                    .to_json()
                    .map(|json| json.to_string())
                    .map_err(|e| raise(e.to_string()))
            })
            .collect::<NifResult<Vec<_>>>()
            .map(|policies| (atoms::residual(), policies)),
    }
}

#[allow(
    clippy::mem_forget,
    reason = "rustler::init! expands to the NIF entry table"
)]
mod entry {
    rustler::init!("Elixir.Marshall.Authorization.Native");
}
