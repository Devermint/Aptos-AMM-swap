// Copyright 2022 OmniBTC Authors. Licensed under Apache-2.0 License.
// Modifications copyright 2025 Devermint
module swap::event {
    use aptos_framework::account;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::Metadata;
    use aptos_std::event::{EventHandle, emit_event};

    friend swap::implements;

    /// Liquidity pool created event.
    public struct CreatedEvent has drop, store {
        creator: address,
        coin_x_meta: address,
        coin_y_meta: address
    }

    /// Liquidity pool added event.
    public struct AddedEvent has drop, store {
        coin_x_meta: address,
        coin_y_meta: address,
        x_val: u64,
        y_val: u64,
        lp_tokens: u64
    }

    /// Liquidity pool removed event.
    public struct RemovedEvent has drop, store {
        coin_x_meta: address,
        coin_y_meta: address,
        x_val: u64,
        y_val: u64,
        lp_tokens: u64
    }

    /// Liquidity pool swapped event.
    public struct SwappedEvent has drop, store {
        coin_x_meta: address,
        coin_y_meta: address,
        x_in: u64,
        y_out: u64
    }

    /// Last price oracle.
    public struct OracleUpdatedEvent has drop, store {
        coin_x_meta: address,
        coin_y_meta: address,
        x_cumulative: u128,
        y_cumulative: u128
    }

    /// Withdraw fee coins
    public struct WithdrewEvent has drop, store {
        coin_meta: address,
        fee: u64
    }

    public struct EventsStore has key {
        created_handle: EventHandle<CreatedEvent>,
        removed_handle: EventHandle<RemovedEvent>,
        added_handle: EventHandle<AddedEvent>,
        swapped_handle: EventHandle<SwappedEvent>,
        oracle_updated_handle: EventHandle<OracleUpdatedEvent>,
        withdrew_handle: EventHandle<WithdrewEvent>
    }

    public(friend) fun initialize(pool_account: &signer) {
        let events_store = EventsStore {
            created_handle: account::new_event_handle<CreatedEvent>(pool_account),
            removed_handle: account::new_event_handle<RemovedEvent>(pool_account),
            added_handle: account::new_event_handle<AddedEvent>(pool_account),
            swapped_handle: account::new_event_handle<SwappedEvent>(pool_account),
            oracle_updated_handle: account::new_event_handle<OracleUpdatedEvent>(
                pool_account
            ),
            withdrew_handle: account::new_event_handle<WithdrewEvent>(pool_account)
        };
        move_to(pool_account, events_store);
    }

    public(friend) fun created_event(
        pool_address: address,
        creator: address,
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>
    ) acquires EventsStore {
        let event_store = borrow_global_mut<EventsStore>(pool_address);
        emit_event(
            &mut event_store.created_handle,
            CreatedEvent {
                creator,
                coin_x_meta: object::object_address(&x_meta),
                coin_y_meta: object::object_address(&y_meta)
            }
        )
    }

    public(friend) fun added_event(
        pool_address: address,
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>,
        x_val: u64,
        y_val: u64,
        lp_tokens: u64
    ) acquires EventsStore {
        let event_store = borrow_global_mut<EventsStore>(pool_address);
        emit_event(
            &mut event_store.added_handle,
            AddedEvent {
                coin_x_meta: object::object_address(&x_meta),
                coin_y_meta: object::object_address(&y_meta),
                x_val,
                y_val,
                lp_tokens
            }
        )
    }

    public(friend) fun removed_event(
        pool_address: address,
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>,
        x_val: u64,
        y_val: u64,
        lp_tokens: u64
    ) acquires EventsStore {
        let event_store = borrow_global_mut<EventsStore>(pool_address);
        emit_event(
            &mut event_store.removed_handle,
            RemovedEvent {
                coin_x_meta: object::object_address(&x_meta),
                coin_y_meta: object::object_address(&y_meta),
                x_val,
                y_val,
                lp_tokens
            }
        )
    }

    public(friend) fun swapped_event(
        pool_address: address,
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>,
        x_in: u64,
        y_out: u64
    ) acquires EventsStore {
        let event_store = borrow_global_mut<EventsStore>(pool_address);
        emit_event(
            &mut event_store.swapped_handle,
            SwappedEvent {
                coin_x_meta: object::object_address(&x_meta),
                coin_y_meta: object::object_address(&y_meta),
                x_in,
                y_out
            }
        )
    }

    public(friend) fun update_oracle_event(
        pool_address: address,
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>,
        x_cumulative: u128,
        y_cumulative: u128
    ) acquires EventsStore {
        let event_store = borrow_global_mut<EventsStore>(pool_address);
        emit_event(
            &mut event_store.oracle_updated_handle,
            OracleUpdatedEvent {
                coin_x_meta: object::object_address(&x_meta),
                coin_y_meta: object::object_address(&y_meta),
                x_cumulative,
                y_cumulative
            }
        )
    }

    public(friend) fun withdrew_event(
        pool_address: address,
        coin_meta: Object<Metadata>,
        fee: u64
    ) acquires EventsStore {
        let event_store = borrow_global_mut<EventsStore>(pool_address);
        emit_event(
            &mut event_store.withdrew_handle,
            WithdrewEvent { coin_meta: object::object_address(&coin_meta), fee }
        )
    }
}
