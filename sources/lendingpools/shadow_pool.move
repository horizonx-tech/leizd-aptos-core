module leizd::shadow_pool {

    use std::signer;
    use std::string::{String};
    use aptos_std::simple_map;
    use aptos_framework::coin;
    use aptos_framework::type_info;
    use leizd::usdz::{USDZ};
    use leizd::permission;
    use leizd::constant;

    friend leizd::money_market;

    struct Pool has key {
        shadow: coin::Coin<USDZ>
    }

    struct Storage has key {
        total_deposited: u128,
        total_conly_deposited: u128,
        total_borrowed: u128,
        deposited: simple_map::SimpleMap<String,u64>,
        borrowed: simple_map::SimpleMap<String,u64>,
    }

    public entry fun init_pool<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
    }

    public(friend) fun deposit_for<C>(
        account: &signer, 
        amount: u64,
        is_collateral_only: bool
    ) acquires Pool, Storage {
        let storage_ref = borrow_global_mut<Storage>(@leizd);
        let pool_ref = borrow_global_mut<Pool>(@leizd);

        // TODO: accrue_interest<C,Shadow>(storage_ref);

        coin::merge(&mut pool_ref.shadow, coin::withdraw<USDZ>(account, amount));
        if (is_collateral_only) {
            storage_ref.total_conly_deposited = storage_ref.total_conly_deposited + (amount as u128);
        } else {
            storage_ref.total_deposited = storage_ref.total_deposited + (amount as u128);
        };
    }

    public(friend) fun withdraw_for<C>(
        account: &signer,
        reciever_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64
    ): u64 acquires Pool, Storage {
        let pool_ref = borrow_global_mut<Pool>(@leizd);
        let storage_ref = borrow_global_mut<Storage>(@leizd);

        // TODO: accrue_interest<C,Shadow>(storage_ref);
        // collect_shadow_fee<C>(pool_ref, liquidation_fee);

        let amount_to_transfer = amount - liquidation_fee;
        coin::deposit<USDZ>(reciever_addr, coin::extract(&mut pool_ref.shadow, amount_to_transfer));
        signer::address_of(account); // TODO: remove
        let withdrawn_amount;
        if (amount == constant::u64_max()) {
            if (is_collateral_only) {
                withdrawn_amount = storage_ref.total_conly_deposited;
            } else {
                withdrawn_amount = storage_ref.total_deposited;
            };
        } else {
            withdrawn_amount = (amount as u128);
        };

        if (is_collateral_only) {
            storage_ref.total_conly_deposited = storage_ref.total_conly_deposited - (withdrawn_amount as u128);
        } else {
            storage_ref.total_deposited = storage_ref.total_deposited - (withdrawn_amount as u128);
        };
        // TODO: assert!(is_shadow_solvent<C>(signer::address_of(depositor)),0);
        (withdrawn_amount as u64)
    }

    fun default_storage<C>(): Storage {
        Storage {
            total_deposited: 0,
            total_conly_deposited: 0,
            total_borrowed: 0,
            deposited: simple_map::create<String,u64>(),
            borrowed: simple_map::create<String,u64>(),
        }
    }

    fun generate_coin_key<C>(): String {
        let coin_type = type_info::type_name<C>();
        coin_type
    }
}