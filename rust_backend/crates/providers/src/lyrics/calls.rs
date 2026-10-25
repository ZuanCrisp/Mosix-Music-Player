//! Native wait dependencies shared by lyrics flights and their extension VMs.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

#[derive(Debug, Default)]
struct State {
    next: u64,
    edges: BTreeMap<u64, BTreeMap<u64, usize>>,
}

#[derive(Clone, Debug, Default)]
pub struct CallGraph(Arc<Mutex<State>>);

#[derive(Debug)]
struct Node {
    graph: CallGraph,
    id: u64,
}

/// A native capability; never deserialize a caller-supplied node identifier.
#[derive(Clone, Debug)]
pub struct CallNode(Arc<Node>);

pub struct CallWait {
    caller: CallNode,
    target: CallNode,
}

impl CallGraph {
    pub fn node(&self) -> CallNode {
        let mut state = self.0.lock().expect("lyrics dependency lock");
        let id = state.next;
        state.next = state
            .next
            .checked_add(1)
            .expect("lyrics node IDs exhausted");
        CallNode(Arc::new(Node {
            graph: self.clone(),
            id,
        }))
    }
}

impl CallNode {
    /// Register before queueing or joining work, and retain until it completes.
    /// The graph lock is never held while waiting for a VM or service result.
    pub fn wait_for(&self, target: &Self) -> Result<CallWait, String> {
        if !Arc::ptr_eq(&self.0.graph.0, &target.0.graph.0) {
            return Err("lyrics caller belongs to a different backend".into());
        }
        let mut state = self.0.graph.0.lock().expect("lyrics dependency lock");
        let mut pending = vec![target.0.id];
        let mut visited = BTreeSet::new();
        while let Some(id) = pending.pop() {
            if id == self.0.id {
                return Err("recursive lyrics call would deadlock".into());
            }
            if visited.insert(id)
                && let Some(edges) = state.edges.get(&id)
            {
                pending.extend(edges.keys().copied());
            }
        }
        *state
            .edges
            .entry(self.0.id)
            .or_default()
            .entry(target.0.id)
            .or_default() += 1;
        Ok(CallWait {
            caller: self.clone(),
            target: target.clone(),
        })
    }
}

impl Drop for CallWait {
    fn drop(&mut self) {
        let mut state = self
            .caller
            .0
            .graph
            .0
            .lock()
            .expect("lyrics dependency lock");
        let edges = state.edges.get_mut(&self.caller.0.id).expect("caller edge");
        let count = edges.get_mut(&self.target.0.id).expect("target edge");
        *count -= 1;
        if *count == 0 {
            edges.remove(&self.target.0.id);
        }
        if edges.is_empty() {
            state.edges.remove(&self.caller.0.id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_cycles_and_keeps_shared_edges_until_the_last_waiter_leaves() {
        let graph = CallGraph::default();
        let a = graph.node();
        let b = graph.node();
        let c = graph.node();
        assert!(a.wait_for(&a).is_err());
        let ab = a.wait_for(&b).unwrap();
        let second_ab = a.wait_for(&b).unwrap();
        let bc = b.wait_for(&c).unwrap();
        assert!(c.wait_for(&a).is_err());
        drop(ab);
        assert!(c.wait_for(&a).is_err());
        drop(second_ab);
        let ca = c.wait_for(&a).unwrap();
        assert!(a.wait_for(&b).is_err());
        assert!(a.wait_for(&CallGraph::default().node()).is_err());
        drop((bc, ca));
        assert!(graph.0.lock().unwrap().edges.is_empty());
    }
}
