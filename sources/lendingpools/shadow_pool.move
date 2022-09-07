module leizd::shadow_pool {

    use std::signer;
    use std::string::{String};
    use aptos_std::simple_map;
    use aptos_framework::coin;
    use aptos_framework::type_info;
    use leizd::usdz::{USDZ};
    use leizd::permission;
    use leizd::constant;
    use leizd::treasury;
    use leizd::stability_pool;
    use leizd::repository;
    use leizd::account_position;

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

    public(friend) fun init_pool<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        stability_pool::init_pool<C>(owner);
        move_to(owner, Pool {
            shadow: coin::zero<USDZ>(),
        });
        move_to(owner, default_storage());
    }

    public(friend) fun deposit_for<C>(
        account: &signer, 
        amount: u64,
        is_collateral_only: bool
    ) acquires Pool, Storage {
        // TODO: assert!(is_available<C>(), 0);

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
        // TODO: assert!(is_available<C>(), 0);

        let pool_ref = borrow_global_mut<Pool>(@leizd);
        let storage_ref = borrow_global_mut<Storage>(@leizd);

        // TODO: accrue_interest<C,Shadow>(storage_ref);
        collect_shadow_fee<C>(pool_ref, liquidation_fee);

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

        // TODO: event
        (withdrawn_amount as u64)
    }

    public(friend) fun borrow_for<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64
    ) acquires Pool, Storage {
        // TODO: assert!(is_available<C>(), 0);
        
        borrower_addr; // TODO
        let pool_ref = borrow_global_mut<Pool>(@leizd);
        let storage_ref = borrow_global_mut<Storage>(@leizd);

        // accrue_interest<C,Shadow>(storage_ref);

        let fee = calculate_entry_fee(amount);
        collect_shadow_fee<C>(pool_ref, fee);

        if (storage_ref.total_deposited - storage_ref.total_conly_deposited < (amount as u128)) {
            // check the staiblity left
            let left = stability_pool::left();
            assert!(left >= (amount as u128), 0);
            borrow_shadow_from_stability_pool<C>(receiver_addr, amount);
            fee = fee + stability_pool::stability_fee_amount(amount);
        } else {
            let deposited = coin::extract(&mut pool_ref.shadow, amount);
            coin::deposit<USDZ>(receiver_addr, deposited);
        };
        storage_ref.total_borrowed = storage_ref.total_borrowed + (amount as u128) + (fee as u128);
        // TODO: assert!(is_shadow_solvent<C>(borrower_addr),0);

        // TODO: event
    }

    public(friend) fun repay<C>(
        account: &signer,
        amount: u64
    ): u64 acquires Pool, Storage {
        // TODO: assert!(is_available<C>(), 0);

        let account_addr = signer::address_of(account);
        let storage_ref = borrow_global_mut<Storage>(@leizd);
        let pool_ref = borrow_global_mut<Pool>(@leizd);

        // TODO: accrue_interest<C,Shadow>(storage_ref);

        let debt_amount = account_position::borrowed_shadow<C>(account_addr);
        let repaid_amount = if (amount >= debt_amount) debt_amount else amount;

        let withdrawn = coin::withdraw<USDZ>(account, repaid_amount);
        coin::merge(&mut pool_ref.shadow, withdrawn);

        storage_ref.total_borrowed = storage_ref.total_borrowed - (repaid_amount as u128);

        // TODO: event
        repaid_amount
    }

    // public fun calc_debt_amount_and_share<C>(
    //     account_addr: address,
    //     total_borrowed: u128,
    //     amount: u64
    // ): (u64, u64) {
    //     let borrower_debt_share = account_position::borrowed_shadow<C>(account_addr); // let borrower_debt_share = debt::balance_of<C,P>(account_addr);
    //     // let debt_supply = debt::supply<C,P>();
    //     let max_amount = (math128::to_amount_roundup((borrower_debt_share as u128), total_borrowed, debt_supply) as u64);

    //     let _amount = 0;
    //     let _repay_share = 0;
    //     if (amount >= max_amount) {
    //         _amount = max_amount;
    //         _repay_share = borrower_debt_share;
    //     } else {
    //         _amount = amount;
    //         _repay_share = (math128::to_share((amount as u128), total_borrowed, debt_supply) as u64);
    //     };
    //     (_amount, _repay_share)
    // }

    fun default_storage(): Storage {
        Storage {
            total_deposited: 0,
            total_conly_deposited: 0,
            total_borrowed: 0,
            deposited: simple_map::create<String,u64>(),
            borrowed: simple_map::create<String,u64>(),
        }
    }

    fun borrow_shadow_from_stability_pool<C>(receiver_addr: address, amount: u64) {
        let borrowed = stability_pool::borrow<C>(receiver_addr, amount);
        coin::deposit(receiver_addr, borrowed);
    }

    /// Repays the shadow to the stability pool if someone has already borrowed from the pool.
    /// @return repaid amount
    fun repay_to_stability_pool<C>(account: &signer, amount: u64): u64 {
        let left = stability_pool::left();
        if (left == 0) {
            return 0
        } else if (left >= (amount as u128)) {
            stability_pool::repay<C>(account, amount);
            return amount
        } else {
            stability_pool::repay<C>(account, (left as u64));
            return (left as u64)
        }
    }

    fun collect_shadow_fee<C>(pool_ref: &mut Pool, liquidation_fee: u64) {
        let fee_extracted = coin::extract(&mut pool_ref.shadow, liquidation_fee);
        treasury::collect_shadow_fee<C>(fee_extracted);
    }

    fun calculate_entry_fee(value: u64): u64 {
        value * repository::entry_fee() / repository::precision() // TODO: rounded up
    }

    fun generate_coin_key<C>(): String {
        let coin_type = type_info::type_name<C>();
        coin_type
    }
}