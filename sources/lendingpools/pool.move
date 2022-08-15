module leizd::pool {

    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use leizd::collateral;
    use leizd::collateral_only;
    use leizd::debt;
    use leizd::repository;
    use leizd::pool_type::{Asset,Shadow};
    use leizd::math;
    use leizd::treasury;
    use leizd::interest_rate;

    const U64_MAX: u64 = 18446744073709551615;
    const DECIMAL_PRECISION: u128 = 1000000000000000000;

    struct Pool<phantom C> has key {
        asset: coin::Coin<C>,
        shadow: coin::Coin<ZUSD>,
    }

    struct Storage<phantom C, phantom P> has key {
        total_deposits: u128,
        total_collateral_only_deposits: u128,
        total_borrows: u128,
        last_updated: u64,
    }

    public entry fun init_pool<C>(owner: &signer) {
        collateral::initialize<C>(owner);
        collateral_only::initialize<C>(owner);
        debt::initialize<C>(owner);
        treasury::initialize<C>(owner);
        repository::new_asset<C>(owner);
        interest_rate::initialize<C>(owner);
        move_to(owner, Pool<C> {
            asset: coin::zero<C>(),
            shadow: coin::zero<ZUSD>()
        });
        move_to(owner, default_storage<C,Asset>());
        move_to(owner, default_storage<C,Shadow>());
    }

    public entry fun deposit<C>(account: &signer, amount: u64, is_collateral_only: bool, is_shadow: bool) acquires Pool, Storage {
        if (is_shadow) {
            deposit_shadow<C>(account, amount, is_collateral_only);
        } else {
            deposit_asset<C>(account, amount, is_collateral_only);
        };
    }

    public entry fun withdraw<C>(account: &signer, amount: u64, is_collateral_only: bool, is_shadow: bool) acquires Pool, Storage {
        if (is_shadow) {
            withdraw_shadow<C>(account, amount, is_collateral_only);
        } else {
            withdraw_asset<C>(account, amount, is_collateral_only);
        };
    }

    public entry fun borrow<C>(account: &signer, amount: u64, is_shadow: bool) acquires Pool, Storage {
        if (is_shadow) {
            borrow_shadow<C>(account, amount);
        } else {
            borrow_asset<C>(account, amount);
        };
    }

    public entry fun repay<C>(account: &signer, amount: u64, is_shadow: bool) acquires Pool, Storage {
        if (is_shadow) {
            repay_shadow<C>(account, amount);
        } else {
            repay_asset<C>(account, amount);
        };
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

    fun withdraw_asset<C>(account: &signer, amount: u64, is_collateral_only: bool) acquires Pool, Storage {
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C,Asset>>(@leizd);

        accrue_interest<C,Asset>(storage_ref);

        let deposited = coin::extract(&mut pool_ref.asset, amount);
        coin::deposit<C>(signer::address_of(account), deposited);
        withdraw_internal<C,Asset>(account, amount, is_collateral_only, storage_ref);
    }

    fun withdraw_shadow<C>(account: &signer, amount: u64, is_collateral_only: bool) acquires Pool, Storage { 
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C,Shadow>>(@leizd);

        accrue_interest<C,Shadow>(storage_ref);

        let deposited = coin::extract(&mut pool_ref.shadow, amount);
        coin::deposit<ZUSD>(signer::address_of(account), deposited);
        withdraw_internal<C,Shadow>(account, amount, is_collateral_only, storage_ref);
    }

    fun withdraw_internal<C,P>(account: &signer, amount: u64, is_collateral_only: bool, storage_ref: &mut Storage<C,P>) {
        let account_addr = signer::address_of(account);
        let burned_share;
        let withdrawn_amount;
        if (amount == U64_MAX) {
            burned_share = collateral_balance<C,P>(account_addr, is_collateral_only);
            withdrawn_amount = math::to_amount((burned_share as u128), storage_ref.total_deposits, collateral_supply<C,P>(is_collateral_only));
        } else {
            burned_share = math::to_share_roundup((amount as u128), storage_ref.total_deposits, collateral_supply<C,P>(is_collateral_only));
            withdrawn_amount = amount;
        };

        if (is_collateral_only) {
            storage_ref.total_collateral_only_deposits = storage_ref.total_collateral_only_deposits - (withdrawn_amount as u128);
            collateral_only::burn<C,P>(account, burned_share);
        } else {
            storage_ref.total_deposits = storage_ref.total_deposits - (withdrawn_amount as u128);
            collateral::burn<C,P>(account, burned_share);
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

    public entry fun flash_liquidate<C>() {
        // TODO
    }

    public entry fun harvest_protocol_fees() {
        // TODO
    }

    fun accrue_interest<C,P>(storage_ref: &mut Storage<C,P>) {
        let now = timestamp::now_microseconds();
        let protocol_share_fee = repository::protocol_share_fee();
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
            last_updated: 0
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

    #[test_only]
    use aptos_framework::account;
    use aptos_framework::managed_coin;
    use leizd::common::{Self,WETH,UNI};
    use leizd::zusd::{Self,ZUSD};
    use leizd::trove;

    #[test(owner=@leizd,account1=@0x111)]
    #[expected_failure(abort_code=524289)]
    public entry fun test_init_pool_twice(owner: signer) {
        account::create_account(signer::address_of(&owner));
        common::init_weth(&owner);
        init_pool<WETH>(&owner);
        init_pool<WETH>(&owner);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth(owner: signer, account1: signer, aptos_framework: signer) acquires Pool, Storage {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account(owner_addr);
        account::create_account(account1_addr);
        common::init_weth(&owner);
        repository::initialize(&owner);
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
    public entry fun test_deposit_weth_for_only_collateral(owner: signer, account1: signer, aptos_framework: signer) acquires Pool, Storage {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account(owner_addr);
        account::create_account(account1_addr);
        common::init_weth(&owner);
        repository::initialize(&owner);
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
    public entry fun test_deposit_shadow(owner: signer, account1: signer, aptos_framework: signer) acquires Pool, Storage {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account(owner_addr);
        account::create_account(account1_addr);
        common::init_weth(&owner);
        trove::initialize(&owner);
        repository::initialize(&owner);
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
    public entry fun test_withdraw_weth(owner: signer, account1: signer, aptos_framework: signer) acquires Pool, Storage {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account(owner_addr);
        account::create_account(account1_addr);
        common::init_weth(&owner);
        repository::initialize(&owner);
        managed_coin::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        assert!(coin::balance<WETH>(account1_addr) == 1000000, 0);

        init_pool<WETH>(&owner);
        deposit<WETH>(&account1, 800000, false, false);

        withdraw<WETH>(&account1, 800000, false, false);
        assert!(coin::balance<WETH>(account1_addr) == 1000000, 0);
        assert!(total_deposits<WETH,Asset>() == 0, 0);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow(owner: signer, account1: signer, aptos_framework: signer) acquires Pool, Storage {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account(owner_addr);
        account::create_account(account1_addr);
        common::init_weth(&owner);
        trove::initialize(&owner);
        repository::initialize(&owner);
        managed_coin::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        assert!(coin::balance<WETH>(account1_addr) == 1000000, 0);
        managed_coin::register<ZUSD>(&account1);
        zusd::mint_for_test(&account1, 1000000);
        assert!(coin::balance<ZUSD>(account1_addr) == 1000000, 0);

        init_pool<WETH>(&owner);
        deposit<WETH>(&account1, 800000, false, true);

        withdraw<WETH>(&account1, 800000, false, true);
        assert!(coin::balance<WETH>(account1_addr) == 1000000, 0);
        assert!(total_deposits<WETH,Shadow>() == 0, 0);
        assert!(coin::balance<ZUSD>(account1_addr) == 1000000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_uni(owner: signer, account1: signer, account2: signer, aptos_framework: signer) acquires Pool, Storage {
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
        repository::initialize(&owner);
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
    public entry fun test_repay_uni(owner: signer, account1: signer, account2: signer, aptos_framework: signer) acquires Pool, Storage {
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
        repository::initialize(&owner);
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