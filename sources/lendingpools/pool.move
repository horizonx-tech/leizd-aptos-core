module leizd::pool {

    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_std::event;
    use leizd::collateral;
    use leizd::collateral_only;
    use leizd::debt;
    use leizd::repository;
    use leizd::pool_type::{Asset,Shadow};
    use leizd::permission;
    use leizd::math;
    use leizd::treasury;
    use leizd::interest_rate;
    use leizd::system_status;
    use leizd::price_oracle;

    friend leizd::system_administrator;

    const U64_MAX: u64 = 18446744073709551615;
    const DECIMAL_PRECISION: u128 = 1000000000000000000;

    struct Pool<phantom C> has key {
        asset: coin::Coin<C>,
        shadow: coin::Coin<ZUSD>,
        is_active: bool,
    }

    struct Storage<phantom C, phantom P> has key {
        total_deposits: u128,
        total_collateral_only_deposits: u128,
        total_borrows: u128,
        last_updated: u64,
    }

    // Events
    struct DepositEvent has store, drop {
        caller: address,
        amount: u64,
        is_shadow: bool,
    }
    struct WithdrawEvent has store, drop {
        caller: address,
        amount: u64,
        is_shadow: bool,
    }
    struct BorrowEvent has store, drop {
        caller: address,
        amount: u64,
        is_shadow: bool,
    }
    struct RepayEvent has store, drop {
        caller: address,
        amount: u64,
        is_shadow: bool,
    }
    struct PoolEventHandle<phantom C> has key, store {
        deposit_event: event::EventHandle<DepositEvent>,
        withdraw_event: event::EventHandle<WithdrawEvent>,
        borrow_event: event::EventHandle<BorrowEvent>,
        repay_event: event::EventHandle<RepayEvent>,
    }

    public entry fun init_pool<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        collateral::initialize<C>(owner);
        collateral_only::initialize<C>(owner);
        debt::initialize<C>(owner);
        treasury::initialize<C>(owner);
        repository::new_asset<C>(owner);
        interest_rate::initialize<C>(owner);
        move_to(owner, Pool<C> {
            asset: coin::zero<C>(),
            shadow: coin::zero<ZUSD>(),
            is_active: true
        });
        move_to(owner, default_storage<C,Asset>());
        move_to(owner, default_storage<C,Shadow>());
        move_to(owner, PoolEventHandle<C> {
            deposit_event: event::new_event_handle<DepositEvent>(owner),
            withdraw_event: event::new_event_handle<WithdrawEvent>(owner),
            borrow_event: event::new_event_handle<BorrowEvent>(owner),
            repay_event: event::new_event_handle<RepayEvent>(owner),
        })
    }

    public fun is_available<C>(): bool acquires Pool {
        let system_is_active = system_status::status();
        let pool_ref = borrow_global<Pool<C>>(@leizd);
        system_is_active && pool_ref.is_active 
    }

    public entry fun deposit<C>(account: &signer, amount: u64, is_collateral_only: bool, is_shadow: bool) acquires Pool, Storage, PoolEventHandle {
        assert!(is_available<C>(), 0);
        if (is_shadow) {
            deposit_shadow<C>(account, amount, is_collateral_only);
        } else {
            deposit_asset<C>(account, amount, is_collateral_only);
        };
        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).deposit_event,
            DepositEvent {
                caller: signer::address_of(account),
                amount,
                is_shadow
            },
        );
    }

    public entry fun withdraw<C>(depositor: &signer, receiver_addr: address, amount: u64, is_collateral_only: bool, is_shadow: bool) acquires Pool, Storage, PoolEventHandle {
        assert!(is_available<C>(), 0);
        if (is_shadow) {
            withdraw_shadow<C>(depositor, receiver_addr, amount, is_collateral_only, 0);
        } else {
            withdraw_asset<C>(depositor, receiver_addr, amount, is_collateral_only, 0);
        };
        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).withdraw_event,
            WithdrawEvent {
                caller: signer::address_of(depositor),
                amount,
                is_shadow
            },
        );
    }

    public entry fun borrow<C>(account: &signer, amount: u64, is_shadow: bool) acquires Pool, Storage, PoolEventHandle {
        assert!(is_available<C>(), 0);
        if (is_shadow) {
            borrow_shadow<C>(account, amount);
        } else {
            borrow_asset<C>(account, amount);
        };
        event::emit_event<BorrowEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).borrow_event,
            BorrowEvent {
                caller: signer::address_of(account),
                amount,
                is_shadow
            },
        );
    }

    public entry fun repay<C>(account: &signer, amount: u64, is_shadow: bool) acquires Pool, Storage, PoolEventHandle {
        assert!(is_available<C>(), 0);
        if (is_shadow) {
            repay_shadow<C>(account, amount);
        } else {
            repay_asset<C>(account, amount);
        };
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).repay_event,
            RepayEvent {
                caller: signer::address_of(account),
                amount,
                is_shadow
            },
        );
    }

    fun deposit_asset<C>(account: &signer, amount: u64, is_collateral_only: bool) acquires Pool, Storage {
        let storage_ref = borrow_global_mut<Storage<C,Asset>>(@leizd);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);

        accrue_interest<C,Asset>(storage_ref);

        let withdrawn = coin::withdraw<C>(account, amount);
        coin::merge(&mut pool_ref.asset, withdrawn);
        deposit_internal<C,Asset>(account, amount, is_collateral_only, storage_ref);
    }

    fun deposit_shadow<C>(account: &signer, amount: u64, is_collateral_only: bool) acquires Pool, Storage {
        let storage_ref = borrow_global_mut<Storage<C,Shadow>>(@leizd);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);

        accrue_interest<C,Shadow>(storage_ref);

        let withdrawn = coin::withdraw<ZUSD>(account, amount);
        coin::merge(&mut pool_ref.shadow, withdrawn);
        deposit_internal<C,Shadow>(account, amount, is_collateral_only, storage_ref);
    }

    fun deposit_internal<C,P>(account: &signer, amount: u64, is_collateral_only: bool, storage_ref: &mut Storage<C,P>) {
        let collateral_share;
        if (is_collateral_only) {
            collateral_share = math::to_share(
                (amount as u128),
                storage_ref.total_collateral_only_deposits,
                collateral_only::supply<C,P>()
            );
            storage_ref.total_collateral_only_deposits = storage_ref.total_deposits + (amount as u128);
            collateral_only::mint<C,P>(account, collateral_share); 
        } else {
            collateral_share = math::to_share(
                (amount as u128),
                storage_ref.total_deposits,
                collateral::supply<C,P>()
            );
            storage_ref.total_deposits = storage_ref.total_deposits + (amount as u128);
            collateral::mint<C,P>(account, collateral_share);
        };
    }

    fun withdraw_asset<C>(depositor: &signer, reciever_addr: address, amount: u64, is_collateral_only: bool, liquidation_fee: u64) acquires Pool, Storage {
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C,Asset>>(@leizd);

        accrue_interest<C,Asset>(storage_ref);

        // TODO: amount to transfer
        let amount_to_transfer = amount - liquidation_fee;
        let deposited = coin::extract(&mut pool_ref.asset, amount_to_transfer);
        coin::deposit<C>(reciever_addr, deposited);
        withdraw_internal<C,Asset>(depositor, amount, is_collateral_only, storage_ref);
    }

    fun withdraw_shadow<C>(depositor: &signer, reciever_addr: address, amount: u64, is_collateral_only: bool, liquidation_fee: u64) acquires Pool, Storage { 
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C,Shadow>>(@leizd);

        accrue_interest<C,Shadow>(storage_ref);

        // TODO: amount to transfer
        let amount_to_transfer = amount - liquidation_fee;
        let deposited = coin::extract(&mut pool_ref.shadow, amount_to_transfer);
        coin::deposit<ZUSD>(reciever_addr, deposited);
        withdraw_internal<C,Shadow>(depositor, amount, is_collateral_only, storage_ref);
    }

    fun withdraw_internal<C,P>(depositor: &signer, amount: u64, is_collateral_only: bool, storage_ref: &mut Storage<C,P>) {
        let depositor_addr = signer::address_of(depositor);
        let burned_share;
        let withdrawn_amount;
        if (amount == U64_MAX) {
            burned_share = collateral_balance<C,P>(depositor_addr, is_collateral_only);
            withdrawn_amount = math::to_amount((burned_share as u128), storage_ref.total_deposits, collateral_supply<C,P>(is_collateral_only));
        } else {
            burned_share = math::to_share_roundup((amount as u128), storage_ref.total_deposits, collateral_supply<C,P>(is_collateral_only));
            withdrawn_amount = amount;
        };

        if (is_collateral_only) {
            storage_ref.total_collateral_only_deposits = storage_ref.total_collateral_only_deposits - (withdrawn_amount as u128);
            collateral_only::burn<C,P>(depositor, burned_share);
        } else {
            storage_ref.total_deposits = storage_ref.total_deposits - (withdrawn_amount as u128);
            collateral::burn<C,P>(depositor, burned_share);
        };
        // TODO is solvent
    }


    fun borrow_asset<C>(account: &signer, amount: u64) acquires Pool, Storage {
        assert!(liquidity<C,Asset>() >= (amount as u128), 0);

        let account_addr = signer::address_of(account);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C,Asset>>(@leizd);

        accrue_interest<C,Asset>(storage_ref);

        let entry_fee = repository::entry_fee();
        let fee = (((amount as u128) * entry_fee / DECIMAL_PRECISION) as u64);
        let fee_extracted = coin::extract(&mut pool_ref.asset, (fee as u64));
        treasury::collect_asset_fee<C>(fee_extracted);

        let deposited = coin::extract(&mut pool_ref.asset, amount);
        coin::deposit<C>(account_addr, deposited);
        borrow_internal<C,Asset>(account, amount, fee, storage_ref);
    }

    fun borrow_shadow<C>(account: &signer, amount: u64) acquires Pool, Storage {
        assert!(liquidity<C,Shadow>() >= (amount as u128), 0);

        let account_addr = signer::address_of(account);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C,Shadow>>(@leizd);

        accrue_interest<C,Shadow>(storage_ref);

        let entry_fee = repository::entry_fee();
        let fee = (((amount as u128) * entry_fee / DECIMAL_PRECISION) as u64);
        let fee_extracted = coin::extract(&mut pool_ref.shadow, (fee as u64));
        treasury::collect_shadow_fee<C>(fee_extracted);

        let deposited = coin::extract(&mut pool_ref.shadow, amount);
        coin::deposit<ZUSD>(account_addr, deposited);
        borrow_internal<C,Shadow>(account, amount, fee, storage_ref);
    }


    fun borrow_internal<C,P>(account: &signer, amount: u64, fee: u64, storage_ref: &mut Storage<C,P>) {
        let debt_share = math::to_share_roundup(((amount + fee) as u128), storage_ref.total_borrows, debt::supply<C,P>());
        storage_ref.total_borrows = storage_ref.total_borrows + (amount as u128) + (fee as u128);
        debt::mint<C,P>(account, debt_share);
    }

    fun repay_asset<C>(account: &signer, amount: u64) acquires Pool, Storage {
        let account_addr = signer::address_of(account);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C,Asset>>(@leizd);

        accrue_interest<C,Asset>(storage_ref);

        let (repaid_amount, repaid_share) = calc_debt_amount_and_share<C,Asset>(account_addr, storage_ref.total_borrows, amount);

        let withdrawn = coin::withdraw<C>(account, repaid_amount);
        coin::merge(&mut pool_ref.asset, withdrawn);

        storage_ref.total_borrows = storage_ref.total_borrows - (repaid_amount as u128);
        debt::burn<C,Asset>(account, repaid_share);
    }

    fun repay_shadow<C>(account: &signer, amount: u64) acquires Pool, Storage {
        let account_addr = signer::address_of(account);
        let storage_ref = borrow_global_mut<Storage<C,Shadow>>(@leizd);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);

        accrue_interest<C,Shadow>(storage_ref);

        let (repaid_amount, repaid_share) = calc_debt_amount_and_share<C,Shadow>(account_addr, storage_ref.total_borrows, amount);

        let withdrawn = coin::withdraw<ZUSD>(account, repaid_amount);
        coin::merge(&mut pool_ref.shadow, withdrawn);

        storage_ref.total_borrows = storage_ref.total_borrows - (repaid_amount as u128);
        debt::burn<C,Shadow>(account, repaid_share);
    }


    public fun calc_debt_amount_and_share<C,P>(account_addr: address, total_borrows: u128, amount: u64): (u64, u64) {
        let borrower_debt_share = debt::balance_of<C,P>(account_addr);
        let debt_supply = debt::supply<C,P>();
        let max_amount = math::to_amount_roundup((borrower_debt_share as u128), total_borrows, debt_supply);

        let _amount = 0;
        let _repay_share = 0;
        if (amount >= max_amount) {
            _amount = max_amount;
            _repay_share = borrower_debt_share;
        } else {
            _amount = amount;
            _repay_share = math::to_share((amount as u128), total_borrows, debt_supply);
        };
        (_amount, _repay_share)
    }

    public entry fun flash_liquidate<C>(account: &signer, target_addr: address, is_shadow: bool) acquires Storage, Pool {
        let protocol_liquidation_fee = (repository::liquidation_fee() as u64);
        if (is_shadow) {
            assert!(is_shadow_solvent<C>(target_addr), 0);
            withdraw_shadow<C>(account, target_addr, U64_MAX, true, protocol_liquidation_fee);
            withdraw_shadow<C>(account, target_addr, U64_MAX, false, protocol_liquidation_fee);
        } else {
            assert!(is_asset_solvent<C>(target_addr), 0);
            withdraw_asset<C>(account, target_addr, U64_MAX, true, protocol_liquidation_fee);
            withdraw_asset<C>(account, target_addr, U64_MAX, false, protocol_liquidation_fee);
        };
    }

    public entry fun collateral_value<C,P>(account: &signer): u64 {
        let account_addr = signer::address_of(account);
        let asset = collateral::balance_of<C,Asset>(account_addr) + collateral_only::balance_of<C,Asset>(account_addr);
        let shadow = collateral::balance_of<C,Shadow>(account_addr) + collateral_only::balance_of<C,Shadow>(account_addr);

        asset * price_oracle::price<C>() + shadow * price_oracle::price<ZUSD>()
    }

    public entry fun debt_value<C,P>(account: &signer): u64 {
        let account_addr = signer::address_of(account);
        let asset = debt::balance_of<C,Asset>(account_addr);
        let shadow = debt::balance_of<C,Shadow>(account_addr);

        asset * price_oracle::price<C>() + shadow * price_oracle::price<ZUSD>()
    }

    public entry fun is_asset_solvent<C>(account_addr: address): bool {
        is_solvent<C,Asset,Shadow>(account_addr)
    }

    public entry fun is_shadow_solvent<C>(account_addr: address): bool {
        is_solvent<C,Shadow,Asset>(account_addr)
    }

    fun is_solvent<COIN,COL,DEBT>(account_addr: address): bool {
        let collateral = collateral::balance_of<COIN,COL>(account_addr) + collateral_only::balance_of<COIN,COL>(account_addr);
        let collateral_value = collateral * price_oracle::price<COIN>();
        let debt = debt::balance_of<COIN,DEBT>(account_addr);
        let debt_value = debt * price_oracle::price<COIN>();

        ((collateral_value / debt_value as u128) <= (repository::liquidation_threshold<COIN>() as u128) / DECIMAL_PRECISION)
    }

    public entry fun harvest_protocol_fees() {
        // TODO
    }

    fun accrue_interest<C,P>(storage_ref: &mut Storage<C,P>) {
        let now = timestamp::now_microseconds();
        let protocol_share_fee = repository::share_fee();
        let rcomp = interest_rate::update_interest_rate<C>(
            now,
            storage_ref.total_deposits,
            storage_ref.total_borrows,
            storage_ref.last_updated,
        );
        let accrued_interest = storage_ref.total_borrows * (rcomp as u128) / (DECIMAL_PRECISION as u128);
        let protocol_share = accrued_interest * protocol_share_fee / DECIMAL_PRECISION;

        let depositors_share = accrued_interest - protocol_share;
        storage_ref.total_borrows = storage_ref.total_borrows + accrued_interest;
        storage_ref.total_deposits = storage_ref.total_deposits + depositors_share;
        storage_ref.last_updated = now;
    }

    fun default_storage<C,P>(): Storage<C,P> {
        Storage<C,P>{
            total_deposits: 0,
            total_collateral_only_deposits: 0,
            total_borrows: 0,
            last_updated: 0,
        }
    }

    fun collateral_balance<C,P>(account_addr: address, is_collateral_only: bool): u64 {
        if (is_collateral_only) {
            collateral_only::balance_of<C,P>(account_addr)
        } else {
            collateral::balance_of<C,P>(account_addr)
        }
    }

    fun collateral_supply<C,P>(is_collateral_only: bool): u128 {
        if (is_collateral_only) {
            collateral_only::supply<C,P>()
        } else {
            collateral::supply<C,P>()
        }
    }

    public entry fun liquidity<C,P>(): u128 acquires Storage {
        let storage_ref = borrow_global<Storage<C,P>>(@leizd);
        storage_ref.total_deposits - storage_ref.total_collateral_only_deposits
    }

    public entry fun total_deposits<C,P>(): u128 acquires Storage {
        borrow_global<Storage<C,P>>(@leizd).total_deposits
    }

    public entry fun total_conly_deposits<C,P>(): u128 acquires Storage {
        borrow_global<Storage<C,P>>(@leizd).total_collateral_only_deposits
    }

    public entry fun total_borrows<C,P>(): u128 acquires Storage {
        borrow_global<Storage<C,P>>(@leizd).total_borrows
    }

    public entry fun last_updated<C,P>(): u64 acquires Storage {
        borrow_global<Storage<C,P>>(@leizd).last_updated
    }

    public(friend) entry fun update_status<C>(active: bool) acquires Pool {
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        pool_ref.is_active = active;
    }

    #[test_only]
    use aptos_framework::account;
    use aptos_framework::managed_coin;
    use leizd::common::{Self,WETH,UNI};
    use leizd::zusd::{Self,ZUSD};
    use leizd::trove;
    use leizd::initializer;

    #[test(owner=@leizd,account1=@0x111)]
    #[expected_failure(abort_code=524289)]
    public entry fun test_init_pool_twice(owner: signer) {
        account::create_account(signer::address_of(&owner));
        common::init_weth(&owner);
        init_pool<WETH>(&owner);
        init_pool<WETH>(&owner);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth(owner: signer, account1: signer, aptos_framework: signer) acquires Pool, Storage, PoolEventHandle {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account(owner_addr);
        account::create_account(account1_addr);
        common::init_weth(&owner);
        initializer::initialize(&owner);
        managed_coin::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        assert!(coin::balance<WETH>(account1_addr) == 1000000, 0);

        init_pool<WETH>(&owner);

        deposit<WETH>(&account1, 800000, false, false);
        assert!(coin::balance<WETH>(account1_addr) == 200000, 0);
        assert!(total_deposits<WETH,Asset>() == 800000, 0);
        assert!(total_conly_deposits<WETH,Asset>() == 0, 0);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_for_only_collateral(owner: signer, account1: signer, aptos_framework: signer) acquires Pool, Storage, PoolEventHandle {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account(owner_addr);
        account::create_account(account1_addr);
        common::init_weth(&owner);
        initializer::initialize(&owner);
        managed_coin::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        assert!(coin::balance<WETH>(account1_addr) == 1000000, 0);

        init_pool<WETH>(&owner);

        deposit<WETH>(&account1, 800000, true, false);
        assert!(coin::balance<WETH>(account1_addr) == 200000, 0);
        assert!(total_deposits<WETH,Asset>() == 0, 0);
        assert!(total_conly_deposits<WETH,Asset>() == 800000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow(owner: signer, account1: signer, aptos_framework: signer) acquires Pool, Storage, PoolEventHandle {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account(owner_addr);
        account::create_account(account1_addr);
        common::init_weth(&owner);
        trove::initialize(&owner);
        initializer::initialize(&owner);
        managed_coin::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        assert!(coin::balance<WETH>(account1_addr) == 1000000, 0);
        managed_coin::register<ZUSD>(&account1);
        zusd::mint_for_test(&account1, 1000000);
        assert!(coin::balance<ZUSD>(account1_addr) == 1000000, 0);

        init_pool<WETH>(&owner);

        deposit<WETH>(&account1, 800000, false, true);
        assert!(coin::balance<WETH>(account1_addr) == 1000000, 0);
        assert!(total_deposits<WETH,Shadow>() == 800000, 0);
        assert!(coin::balance<ZUSD>(account1_addr) == 200000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_weth(owner: signer, account1: signer, aptos_framework: signer) acquires Pool, Storage, PoolEventHandle {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account(owner_addr);
        account::create_account(account1_addr);
        common::init_weth(&owner);
        initializer::initialize(&owner);
        managed_coin::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        assert!(coin::balance<WETH>(account1_addr) == 1000000, 0);

        init_pool<WETH>(&owner);
        deposit<WETH>(&account1, 800000, false, false);

        withdraw<WETH>(&account1, account1_addr, 800000, false, false);
        assert!(coin::balance<WETH>(account1_addr) == 1000000, 0);
        assert!(total_deposits<WETH,Asset>() == 0, 0);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow(owner: signer, account1: signer, aptos_framework: signer) acquires Pool, Storage, PoolEventHandle {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account(owner_addr);
        account::create_account(account1_addr);
        common::init_weth(&owner);
        trove::initialize(&owner);
        initializer::initialize(&owner);
        managed_coin::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        assert!(coin::balance<WETH>(account1_addr) == 1000000, 0);
        managed_coin::register<ZUSD>(&account1);
        zusd::mint_for_test(&account1, 1000000);
        assert!(coin::balance<ZUSD>(account1_addr) == 1000000, 0);

        init_pool<WETH>(&owner);
        deposit<WETH>(&account1, 800000, false, true);

        withdraw<WETH>(&account1, account1_addr, 800000, false, true);
        assert!(coin::balance<WETH>(account1_addr) == 1000000, 0);
        assert!(total_deposits<WETH,Shadow>() == 0, 0);
        assert!(coin::balance<ZUSD>(account1_addr) == 1000000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_uni(owner: signer, account1: signer, account2: signer, aptos_framework: signer) acquires Pool, Storage, PoolEventHandle {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        let account2_addr = signer::address_of(&account2);
        account::create_account(owner_addr);
        account::create_account(account1_addr);
        account::create_account(account2_addr);
        common::init_weth(&owner);
        common::init_uni(&owner);
        trove::initialize(&owner);
        initializer::initialize(&owner);
        managed_coin::register<UNI>(&account1);
        managed_coin::mint<UNI>(&owner, account1_addr, 1000000);
        managed_coin::register<ZUSD>(&account1);
        zusd::mint_for_test(&account1, 1000000);
        managed_coin::register<WETH>(&account2);
        managed_coin::mint<WETH>(&owner, account2_addr, 1000000);
        managed_coin::register<UNI>(&account2);
        managed_coin::register<ZUSD>(&account2);
        
        init_pool<WETH>(&owner);
        init_pool<UNI>(&owner);

        // Lender: 
        // deposit ZUSD for WETH
        // deposit UNI
        deposit<WETH>(&account1, 800000, false, true);
        deposit<UNI>(&account1, 800000, false, false);

        // Borrower:
        // deposit WETH
        // borrow  ZUSD
        deposit<WETH>(&account2, 600000, false, false);
        borrow<WETH>(&account2, 300000, true);

        // Borrower:
        // deposit ZUSD for UNI
        // borrow UNI
        deposit<UNI>(&account2, 200000, false, true);
        borrow<UNI>(&account2, 100000, false);
        assert!(coin::balance<UNI>(account2_addr) == 100000, 0);
        assert!(coin::balance<ZUSD>(account2_addr) == 100000, 0);
        assert!(debt::balance_of<UNI,Asset>(account2_addr) == 100500, 0); // 0.5% fee
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_uni(owner: signer, account1: signer, account2: signer, aptos_framework: signer) acquires Pool, Storage, PoolEventHandle {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        let account2_addr = signer::address_of(&account2);
        account::create_account(owner_addr);
        account::create_account(account1_addr);
        account::create_account(account2_addr);
        common::init_weth(&owner);
        common::init_uni(&owner);
        trove::initialize(&owner);
        initializer::initialize(&owner);
        managed_coin::register<UNI>(&account1);
        managed_coin::mint<UNI>(&owner, account1_addr, 1000000);
        managed_coin::register<ZUSD>(&account1);
        zusd::mint_for_test(&account1, 1000000);
        managed_coin::register<WETH>(&account2);
        managed_coin::mint<WETH>(&owner, account2_addr, 1000000);
        managed_coin::register<UNI>(&account2);
        managed_coin::register<ZUSD>(&account2);
        
        init_pool<WETH>(&owner);
        init_pool<UNI>(&owner);

        // Lender: 
        // deposit ZUSD for WETH
        // deposit UNI
        deposit<WETH>(&account1, 800000, false, true);
        deposit<UNI>(&account1, 800000, false, false);

        // Borrower:
        // deposit WETH
        // borrow  ZUSD
        deposit<WETH>(&account2, 600000, false, false);
        borrow<WETH>(&account2, 300000, true);

        // Borrower:
        // deposit ZUSD for UNI
        // borrow UNI
        deposit<UNI>(&account2, 200000, false, true);
        borrow<UNI>(&account2, 100000, false);
        
        // Borrower:
        // repay UNI
        repay<UNI>(&account2, 100000, false);
        assert!(coin::balance<UNI>(account2_addr) == 0, 0);
        assert!(coin::balance<ZUSD>(account2_addr) == 100000, 0);
        assert!(debt::balance_of<UNI,Asset>(account2_addr) == 700, 0); // 0.5% entry fee + 0.2% interest
    }
}