module leizd_aptos_trove::trove {
    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use std::comparator;
    use std::vector;
    use aptos_std::simple_map;
    use aptos_std::event;
    use aptos_framework::account;
    use aptos_framework::coin;
    use leizd_aptos_lib::math128;
    use leizd_aptos_common::permission;
    use leizd_aptos_trove::usdz::{Self, USDZ};
    use leizd_aptos_external::price_oracle;
    use leizd_aptos_common::coin_key;
    use leizd_aptos_lib::constant;
    use leizd_aptos_trove::collateral_manager;
    use leizd_aptos_trove::base_rate;    
    use leizd_aptos_trove::borrowing_rate;

    const ENOT_SUPPORTED: u64 = 1;
    const EALREADY_SUPPORTED: u64 = 2;
    const ECR_UNDER_MINIMUM_CR: u64 = 3;
    const EACCOUNT_NOT_REDEEMABLE: u64 = 4;
    const ETROVE_IS_ALREADY_ACTIVE: u64 = 5;
    const EDEBT_IS_UNDER_MIN_NET_DEBT: u64 = 6;
    const ECOLLATERAL_RATIO_IS_UNDER_CRITICAL_COLLATERAL_RATIO: u64 = 7;
    const ECOLLATERAL_RATIO_IS_UNDER_MINIMUM_COLLATERAL_RATIO: u64 = 8;
    const ETOTAL_COLLATERAL_RATIO_IS_UNDER_CRITICAL_COLLATERAL_RATIO: u64 = 9;
    const ETROVE_IS_NOT_ACTIVE: u64 = 10;
    const EIN_RECOVERY_MODE: u64 = 10;
    const PRECISION: u64 = 1000000;
    const MINUMUM_COLLATERAL_RATIO: u128 = 110; // 100%
    const CRITICAL_COLLATERAL_RATIO: u128 = 150; // 150%
    const MIN_NET_DEBT: u64 = 1800 * 100000000; // Minimum amount of net USDZ debt a trove must have
    const GAS_COMPENSATION: u64 = 10 * 100000000;
    const BORROWING_FEE_PERCENTAGE: u64 = 1; // 1% TODO

    struct Trove has key, store {
        amounts: simple_map::SimpleMap<String, Position>,
        borrowed: u64,
    }

    struct Position has key, store, copy, drop {
        borrowed: u64,
        deposited: u64
    }

    struct Vault<phantom C> has key, store {
        coin: coin::Coin<C>
    }

    struct GasPool has key, store {
        coin: coin::Coin<USDZ>
    }

    struct BorrowingFeeVault has key, store {
        coin: coin::Coin<USDZ>
    }

    struct SupportedCoins has key {
        coins: vector<String>
    }

    struct OpenTroveEvent has store, drop {
        caller: address,
        amount: u64,
        collateral_amount: u64,
    }

    struct CloseTroveEvent has store, drop {
        caller: address,
    }

    struct RepayEvent has store, drop {
        caller: address,
        amount: u64,
        collateral_amount: u64,
    }

    struct TroveEventHandle<phantom C> has key, store {
        open_trove_event: event::EventHandle<OpenTroveEvent>,
        close_trove_event: event::EventHandle<CloseTroveEvent>,
        repay_event: event::EventHandle<RepayEvent>,
    }
    
    public fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        initialize_internal(owner);
    }

    public fun minimum_collateral_ratio(): u128 {
        (PRECISION  as u128) * (MINUMUM_COLLATERAL_RATIO as u128) / 100
    }

    fun initialize_internal(owner: &signer) {
        usdz::initialize(owner);
        collateral_manager::initialize(owner);
        base_rate::initialize(owner);
        move_to(owner, SupportedCoins{
            coins: vector::empty<String>()
        });
        move_to(owner, GasPool{
            coin: coin::zero<USDZ>()
        });
        move_to(owner, BorrowingFeeVault{
            coin: coin::zero<USDZ>()
        })
    }

    public fun add_supported_coin<C>(owner: &signer) acquires SupportedCoins {
        permission::assert_owner(signer::address_of(owner));
        add_supported_coin_internal<C>(owner);
    }

    fun add_supported_coin_internal<C>(owner: &signer) acquires SupportedCoins {
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);
        assert!(!is_coin_supported<C>(), error::invalid_argument(EALREADY_SUPPORTED));
        move_to(owner, TroveEventHandle<C> {
            open_trove_event: account::new_event_handle<OpenTroveEvent>(owner),
            close_trove_event: account::new_event_handle<CloseTroveEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
        });
        move_to(owner, Vault<C>{coin: coin::zero<C>()});
        let supported_coins = borrow_global_mut<SupportedCoins>(owner_address);
        vector::push_back<String>(&mut supported_coins.coins, key_of<C>());
        collateral_manager::add_supported_coin<C>(owner);
    }

    public fun redeemable(target: address): bool acquires SupportedCoins, Trove {
        collateral_ratio_of(target) <= total_collateral_ratio()
    }

    public fun total_deposited_in_usdz():u64 {
        let i = 0;
        let total = 0;
        while(i < collateral_manager::coin_length()) {
            let (key, deposit) = collateral_manager::deposited(i);
            total = total + current_amount_in_usdz(deposit, key);
            i = i + 1
        };
        total
    }

    fun composite_debt(debt: u64): u64 {
        debt + GAS_COMPENSATION
    }

    public fun total_collateral_ratio(): u128 {
        let deposited = total_deposited_in_usdz();
        let borrowed = collateral_manager::total_borrowed();
        collateral_ratio(deposited, borrowed)
    }

    public fun total_collateral_ratio_after_update_trove(collateral_in_usdz: u64, debt: u64, neg: bool): u128 {
        let deposited = total_deposited_in_usdz();
        let borrowed = collateral_manager::total_borrowed();
        if (neg) {
            deposited = deposited - collateral_in_usdz;
            borrowed = borrowed - debt;
        } else {
            deposited = deposited + collateral_in_usdz;
            borrowed = borrowed + debt;
        };
        collateral_ratio(deposited, borrowed)
    }

    public fun collateral_ratio_of(account: address): u128 acquires Trove, SupportedCoins {
        collateral_ratio_of_with(string::utf8(b""), 0, 0, false, account)
    }

    fun collateral_ratio_of_with(key: String, additional_deposited: u64, additional_borrowed: u64, neg: bool, account: address): u128 acquires Trove, SupportedCoins {
        let coins = borrow_global<SupportedCoins>(permission::owner_address()).coins;
        let total_deposited = 0;
        let i = 0;
        while (i < vector::length(&coins)) {
            let coin_key = *vector::borrow<String>(&coins, i);
             total_deposited = total_deposited + current_amount_in_usdz(trove_amount_of(account, coin_key), coin_key);
             i = i + 1
        };
        if (string::is_empty(&key)) {
            return collateral_ratio(total_deposited, borrow_global<Trove>(account).borrowed)
        };
        let borrowed = borrow_global<Trove>(account).borrowed;
        if (neg) {
            total_deposited = total_deposited - current_amount_in_usdz(additional_deposited, key);
            borrowed = borrowed - additional_borrowed;
        } else {
            total_deposited = total_deposited + current_amount_in_usdz(additional_deposited, key);
            borrowed = borrowed + additional_borrowed;
        };
        collateral_ratio(total_deposited, borrowed)
    }

    public fun collateral_ratio_after_update_trove(key: String, amount: u64, usdz_amount: u64, neg: bool, account: address): u128 acquires Trove, SupportedCoins {
        collateral_ratio_of_with(key, amount, usdz_amount, neg, account)
    }

    fun collateral_ratio(deposited: u64, borrowed: u64): u128 {
        if (borrowed == 0) {
            return constant::u128_max()
        };
        ((PRECISION as u128) * (deposited as u128)) / (borrowed as u128)
    }

    public fun trove_amount_of(account: address, key: String): u64 acquires Trove {
        if(!exists<Trove>(account)) {
            return 0
        };
        let trove = borrow_global<Trove>(account);
        if (simple_map::contains_key(&trove.amounts, &key)){
            return simple_map::borrow(&trove.amounts, &key).deposited
        };
        0
    }

    public fun trove_amount<C>(account: address): u64 acquires Trove {
        trove_amount_of(account, coin_key::key<C>())
    }
    
    public fun open_trove<C>(account: &signer, amount: u64, usdz_amount: u64) acquires Vault, Trove, TroveEventHandle, SupportedCoins {
        open_trove_internal<C>(account, amount, usdz_amount);
    }

    fun is_key_equals<C>(key: String): bool {
        comparator::is_equal(&comparator::compare(&key, &key_of<C>()))
    }

    fun key_of<C>(): String {
        coin_key::key<C>()
    }

    public fun redeem<C>(account: &signer, target_accounts: vector<address>, amount: u64) acquires Trove, Vault, SupportedCoins {
        redeem_internal<C>(account, target_accounts, amount)
    }

    fun redeem_internal<C>(account: &signer, target_accounts: vector<address>, usdz_amount: u64) acquires Trove, Vault, SupportedCoins {
        let redeemed_in_collateral_coin = 0;
        let unredeemed = current_amount_in(usdz_amount, key_of<C>());
        let total_usdz_supply_at_start = collateral_manager::total_borrowed();
        let i = 0;
        while (i < vector::length(&target_accounts)){
            let target_account = vector::borrow<address>(&target_accounts, i);
            assert!(redeemable(*target_account), EACCOUNT_NOT_REDEEMABLE);
            let target_amount = trove_amount<C>(*target_account);
            if (target_amount > redeemed_in_collateral_coin + unredeemed) {
                target_amount = unredeemed
            };
            let usdz_amount = current_amount_in_usdz(target_amount, key_of<C>());
            usdz::burn(account, usdz_amount);
            let vault = borrow_global_mut<Vault<C>>(permission::owner_address());
            let deposited = coin::extract(&mut vault.coin, target_amount);
            coin::deposit<C>(signer::address_of(account), deposited);
            decrease_trove_amount(*target_account, key_of<C>(), target_amount, usdz_amount);
            redeemed_in_collateral_coin = redeemed_in_collateral_coin + target_amount;
            unredeemed = unredeemed - target_amount;
            if (unredeemed == 0) {
                break
            }
        };
        base_rate::update_base_rate_from_redemption(usdz_amount - unredeemed, total_usdz_supply_at_start)
    }

    fun increase_trove_amount(account: address,key:String, collateral_amount:u64 ,usdz_amount: u64) acquires Trove {
        update_trove_amount(account, key, collateral_amount, usdz_amount, false)
    }

    fun decrease_trove_amount(account: address,key:String, collateral_amount:u64 ,usdz_amount: u64) acquires Trove {
        update_trove_amount(account, key, collateral_amount, usdz_amount, true)
    }

    fun update_trove_amount(account: address, key: String, collateral_amount:u64 ,usdz_amount: u64, neg: bool) acquires Trove {
        collateral_manager::update_statistics(key, collateral_amount, usdz_amount, neg);
        let trove = borrow_global_mut<Trove>(account);
        if (!simple_map::contains_key<String,Position>(&mut trove.amounts, &key)) {
            simple_map::add<String,Position>(&mut trove.amounts, key, Position{deposited: 0, borrowed: 0});
        };
        let position = simple_map::borrow_mut<String,Position>(&mut trove.amounts, &key);
        if (!neg) {
            position.deposited = position.deposited + collateral_amount;
            position.borrowed = position.borrowed + usdz_amount;
            trove.borrowed = trove.borrowed + usdz_amount;
            return
        };
        position.deposited = position.deposited - collateral_amount;
        position.borrowed = position.borrowed - usdz_amount;
        trove.borrowed = trove.borrowed - usdz_amount;
    }

//    fun requireMaxFeePercentage(_input: RedeemInput){}
    fun requireAfterBootstrapPeriod() {}
    fun requireTCRoverMCR(_price: u64) {}
    fun requireAmountGreaterThanZero(_amount: u64) {}
    fun requireUSDZBalanceCoversRedemption() {}

    fun validate_open_trove<C>(amount: u64, usdz_amount: u64, composite_usdz_amount: u64, account: address) acquires SupportedCoins, Trove {
        let key = key_of<C>();
        validate_internal<C>();
        require_cr_above_minimum_cr(key, amount, usdz_amount, false, account);
        require_at_least_min_net_debt(usdz_amount);
        let icr = collateral_ratio_after_update_trove(key, amount, composite_usdz_amount, false, account);
        if (is_recovery_mode()) {
            require_irc_is_above_ccr(collateral_ratio_after_update_trove(key, amount, composite_usdz_amount, false, account));
            return
        };
        require_icr_is_above_mcr(icr);
        let new_tcr = total_collateral_ratio_after_update_trove(current_amount_in_usdz(amount, key), composite_usdz_amount, false);
        require_new_tcr_is_above_ccr(new_tcr)
    }

    fun require_icr_is_above_mcr(icr: u128) {
        assert!(icr >= MINUMUM_COLLATERAL_RATIO, ECOLLATERAL_RATIO_IS_UNDER_MINIMUM_COLLATERAL_RATIO)
    }

    fun require_new_tcr_is_above_ccr(new_tcr: u128) {
        assert!(new_tcr >= CRITICAL_COLLATERAL_RATIO, ETOTAL_COLLATERAL_RATIO_IS_UNDER_CRITICAL_COLLATERAL_RATIO)
    }

    fun require_irc_is_above_ccr(icr: u128) {
        assert!(icr >= CRITICAL_COLLATERAL_RATIO, ECOLLATERAL_RATIO_IS_UNDER_CRITICAL_COLLATERAL_RATIO)
    }

    fun require_at_least_min_net_debt(usdz_amount: u64) {
        assert!(usdz_amount >= MIN_NET_DEBT, EDEBT_IS_UNDER_MIN_NET_DEBT)
    }

    fun require_cr_above_minimum_cr(key: String, amount: u64, usdz_amount:u64, neg: bool, account: address) acquires SupportedCoins, Trove {
        assert!(collateral_ratio_after_update_trove(key, amount, usdz_amount, neg, account) > minimum_collateral_ratio(), ECR_UNDER_MINIMUM_CR)
    }

    fun validate_close_trove<C>(position: Position) acquires SupportedCoins {
        validate_internal<C>();
        require_not_in_recovery_mode();
        let key = key_of<C>();
        let new_tcr = total_collateral_ratio_after_update_trove(current_amount_in_usdz(position.deposited, key), position.borrowed, false);
        require_new_tcr_is_above_ccr(new_tcr);
        require_trove_is_active(position);

        // TODO: need it ?
        //let trove = borrow_global<Trove>(account);
        //let position = simple_map::borrow<String,Position>(&trove.amounts, &key_of<C>());
        //require_cr_above_minimum_cr(key_of<C>(), position.deposited, position.borrowed, true, account)
    }

    fun require_trove_is_active(position: Position) {
        assert!(position.deposited != 0, ETROVE_IS_NOT_ACTIVE)
    }

    fun require_not_in_recovery_mode() {
        assert!(!is_recovery_mode(), EIN_RECOVERY_MODE)
    }

    fun validate_repay<C>() acquires SupportedCoins {
        validate_internal<C>()
    }

    fun validate_internal<C>() acquires SupportedCoins {
        assert!(is_coin_supported<C>(), error::invalid_argument(ENOT_SUPPORTED))
    }

    fun is_coin_supported<C>(): bool acquires SupportedCoins {
        let coins = borrow_global<SupportedCoins>(permission::owner_address()).coins;
        let i = 0;
        while (i < vector::length(&coins)){
            let coin = vector::borrow<String>(&coins, i);
            if (is_key_equals<C>(*coin)) {
                return true
            };
            i = i + 1;
        };
        false
    }

    public fun borrowing_fee(debt_amount: u64):u64 {
        borrowing_rate::borrowing_fee(debt_amount)
    }

    public fun close_trove<C>(account: &signer) acquires Trove, TroveEventHandle, Vault, SupportedCoins {
        close_trove_internal<C>(account);
    }

    public fun repay<C>(account: &signer, collateral_amount: u64) acquires Trove, Vault, TroveEventHandle, SupportedCoins {
        repay_internal<C>(account, collateral_amount);
    }

    fun current_amount_in_usdz(amount: u64, key: String): u64 {
        let (price, _decimals) = price_oracle::price_of(&key);
        let decimals = (_decimals as u128);
        let decimals_usdz = (coin::decimals<usdz::USDZ>() as u128);

        let numerator = price * (amount as u128) * math128::pow(10, decimals_usdz);
        let dominator = (math128::pow(10, decimals * 2));
        (numerator / dominator as u64)
    }

    fun current_amount_in(usdz_amount: u64, key: String): u64 {
        let (price, _decimals) = price_oracle::price_of(&key);
        let decimals = (_decimals as u128);
        let decimals_usdz = (coin::decimals<usdz::USDZ>() as u128);
        let numerator = (usdz_amount as u128) * math128::pow(10, decimals * 2);
        let dominator = (price * math128::pow(10, decimals_usdz));
        (numerator / dominator as u64)
    }

    fun open_trove_internal<C>(account: &signer, collateral_amount: u64, amount: u64) acquires Vault, Trove, TroveEventHandle, SupportedCoins {
        let account_addr = signer::address_of(account);
        if (!exists<Trove>(account_addr)) {
            move_to(account, Trove {
                amounts: simple_map::create<String,Position>(),
                borrowed: 0,
            });
        };
        let recovery_mode = is_recovery_mode();
        let net_debt = amount;
        let borrowing_fee = borrowing_fee(amount);
        if (!recovery_mode){ 
            net_debt = net_debt + borrowing_fee;
        };
        let composite_debt = composite_debt(net_debt);
        validate_open_trove<C>(collateral_amount, net_debt, composite_debt, account_addr);
        base_rate::decay_base_rate_from_borrowing();
        increase_trove_amount(account_addr, key_of<C>(), collateral_amount, net_debt);
        let owner_address = permission::owner_address();
        let treasury = borrow_global_mut<Vault<C>>(owner_address);
        coin::merge(&mut treasury.coin, coin::withdraw<C>(account, collateral_amount));
//        let borrowing_fee_vault = borrow_global_mut<BorrowingFeeVault>(owner_address);
        // TODO: mint borrowing fee to borrowing_fee_vault 
        usdz::mint(account, amount);
        event::emit_event<OpenTroveEvent>(
            &mut borrow_global_mut<TroveEventHandle<C>>(permission::owner_address()).open_trove_event,
            OpenTroveEvent {
                caller: account_addr,
                amount,
                collateral_amount
            },
        )
    }

    fun is_recovery_mode(): bool {
        total_collateral_ratio() < CRITICAL_COLLATERAL_RATIO
    }

    fun close_trove_internal<C>(account: &signer) acquires Trove, TroveEventHandle, Vault, SupportedCoins {
        let account_addr = signer::address_of(account);
        let troves = borrow_global_mut<Trove>(account_addr);
        let position = simple_map::borrow_mut<String, Position>(&mut troves.amounts, &key_of<C>());
        validate_close_trove<C>(*position);
        usdz::burn(account, position.borrowed);
        let owner_addr = permission::owner_address();
        let vault = borrow_global_mut<Vault<C>>(owner_addr);
        coin::deposit(account_addr, coin::extract(&mut vault.coin, (position.deposited)));
        decrease_trove_amount(account_addr, key_of<C>(), position.deposited, position.borrowed);
        event::emit_event<CloseTroveEvent>(
            &mut borrow_global_mut<TroveEventHandle<C>>(permission::owner_address()).close_trove_event,
            CloseTroveEvent {
                caller: signer::address_of(account),
            },
        );
    }

    fun repay_internal<C>(account: &signer, collateral_amount: u64) acquires Vault, Trove, TroveEventHandle, SupportedCoins {
        validate_repay<C>();
        let amount = current_amount_in_usdz(collateral_amount, key_of<C>());
        usdz::burn(account, amount);
        let vault = borrow_global_mut<Vault<C>>(permission::owner_address());
        decrease_trove_amount(signer::address_of(account), key_of<C>(), collateral_amount, amount);
        coin::deposit<C>(signer::address_of(account), coin::extract(&mut vault.coin, collateral_amount));
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<TroveEventHandle<C>>(permission::owner_address()).repay_event,
            RepayEvent {
                caller: signer::address_of(account),
                amount,
                collateral_amount
            },
        );
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd_aptos_lib::math64;
    #[test_only]
    use leizd_aptos_common::test_coin::{Self,USDC,USDT};
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    const USDC_AMT: u64 = 10000 * 100000000;


    #[test_only]
    fun set_up(owner: &signer, account1: &signer, aptos_framework: &signer) acquires SupportedCoins {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        let amount = USDC_AMT;
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        managed_coin::register<USDC>(account1);
        managed_coin::register<USDT>(account1);
        initialize_oracle(owner);
        managed_coin::register<usdz::USDZ>(account1);
        managed_coin::mint<USDC>(owner, account1_addr, amount);
        managed_coin::mint<USDT>(owner, account1_addr, amount);
        initialize_internal(owner);
        add_supported_coin_internal<USDC>(owner);
        add_supported_coin_internal<USDT>(owner);
        timestamp::set_time_has_started_for_testing(aptos_framework);
    }

    #[test_only]
    fun set_up_account(owner: &signer, account: &signer) {
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDC>(account);
        managed_coin::register<USDT>(account);
        managed_coin::register<usdz::USDZ>(account);
        managed_coin::mint<USDC>(owner, account_addr, USDC_AMT);
        managed_coin::mint<USDT>(owner, account_addr, USDC_AMT);
    }

    #[test_only]
    fun initialize_oracle(owner: &signer) {
        price_oracle::initialize(owner);
        price_oracle::register_oracle_with_fixed_price<USDC>(owner, 1000000, 6, false);
        price_oracle::register_oracle_with_fixed_price<USDT>(owner, 1000000, 6, false);
        price_oracle::change_mode<USDC>(owner, 1);
        price_oracle::change_mode<USDT>(owner, 1);
    }

    #[test_only]
    fun initialize_oracle_coin<C>(owner: &signer, price: u128, decimals: u8) {
        price_oracle::register_oracle_with_fixed_price<C>(owner, price, decimals, false);
        price_oracle::change_mode<C>(owner, 1);
    }

    #[test(owner=@leizd_aptos_trove)]
    fun test_initialize(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize_internal(owner);
    }
    #[test(owner=@leizd_aptos_trove)]
    #[expected_failure(abort_code = 524290)]
    fun test_initialize_twice(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize_internal(owner);
        initialize_internal(owner);
    }
    #[test(account=@0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_initialize_with_not_owner(account: &signer) {
        initialize_internal(account);
    }
    #[test(owner=@leizd_aptos_trove)]
    fun test_add_supported_coin(owner: &signer) acquires SupportedCoins {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize_internal(owner);
        add_supported_coin_internal<USDC>(owner);
        assert!(is_coin_supported<USDC>(), 0);
        assert!(exists<TroveEventHandle<USDC>>(owner_addr), 0);
    }
    #[test(owner=@leizd_aptos_trove)]
    #[expected_failure(abort_code = 65538)]
    fun test_add_supported_coin_twice(owner: &signer) acquires SupportedCoins {
        account::create_account_for_test(signer::address_of(owner));
        initialize_internal(owner);
        add_supported_coin_internal<USDC>(owner);
        add_supported_coin_internal<USDC>(owner);
    }
    #[test(owner=@leizd_aptos_trove, account = @0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_add_supported_coin_with_not_owner(owner: &signer, account: &signer) acquires SupportedCoins {
        account::create_account_for_test(signer::address_of(owner));
        initialize_internal(owner);
        add_supported_coin_internal<USDC>(account);
    }

    #[test(owner=@leizd_aptos_trove,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_open_trove(owner: signer, account1: signer, aptos_framework: signer) acquires Vault, Trove, TroveEventHandle, SupportedCoins {
        set_up(&owner, &account1, &aptos_framework);
        let account1_addr = signer::address_of(&account1);
        let want = USDC_AMT * math64::pow(10, 8 - 6) * 8 / 10;
        open_trove<USDC>(&account1, USDC_AMT, want);
        assert!(comparator::is_equal(&comparator::compare(
            &usdz::balance_of(account1_addr),
            &want
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            &trove_amount<USDC>(account1_addr),
            &USDC_AMT
        )), 0);
        assert!(coin::balance<USDC>(account1_addr) == 0, 0);
        // add more USDC
        managed_coin::mint<USDC>(&owner, account1_addr, USDC_AMT);
        open_trove<USDC>(&account1, USDC_AMT, want);
        assert!(comparator::is_equal(&comparator::compare(
            &trove_amount<USDC>(account1_addr),
            &(USDC_AMT * 2)
        )), 0);

        assert!(comparator::is_equal(&comparator::compare(
            &usdz::balance_of(account1_addr),
            &(want * 2)
        )), 0);
        // add USDT
        open_trove<USDT>(&account1, USDC_AMT, want);
        assert!(comparator::is_equal(&comparator::compare(
            &usdz::balance_of(account1_addr),
            &(want * 3)
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            &trove_amount<USDT>(account1_addr),
            &USDC_AMT
        )), 0);        
    }

    #[test(owner=@leizd_aptos_trove,account1=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 3)]
    fun test_open_trove_below_min_cr(owner: signer, account1: signer, aptos_framework: signer) acquires Vault, Trove, TroveEventHandle, SupportedCoins {
        set_up(&owner, &account1, &aptos_framework);
        let account1_addr = signer::address_of(&account1);
        // collateral raio under 110%
        let want = USDC_AMT * math64::pow(10, 8 - 6) * 101 / 110;
        open_trove<USDC>(&account1, USDC_AMT, want);
        assert!(comparator::is_equal(&comparator::compare(
            &usdz::balance_of(account1_addr),
            &want
        )), 0);
    }

    #[test(owner=@leizd_aptos_trove,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_close_trove(owner: signer, account1: signer, aptos_framework: signer) acquires Vault, Trove, TroveEventHandle, SupportedCoins {
        set_up(&owner, &account1, &aptos_framework);
        let account1_addr = signer::address_of(&account1);
        let want = USDC_AMT * math64::pow(10, 8 - 6) * 90 / 110;
        open_trove<USDC>(&account1, USDC_AMT, want);
        close_trove<USDC>(&account1);
        assert!(comparator::is_equal(&comparator::compare(
            &coin::balance<USDC>(account1_addr),
            &USDC_AMT
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            &usdz::balance_of(account1_addr),
            &0
        )), 0);
        let trove = borrow_global<Trove>(account1_addr);
        assert!(comparator::is_equal(&comparator::compare(
            &trove.borrowed,
            &0
        )), 0);
        let amount = simple_map::borrow<String, Position>(&trove.amounts, &key_of<USDC>());
        assert!(comparator::is_equal(&comparator::compare(
            &amount.borrowed,
            &0
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            &amount.deposited,
            &0
        )), 0);
    }

    #[test(owner=@leizd_aptos_trove,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_current_amount_in(owner: signer, account1: signer, aptos_framework: signer) acquires SupportedCoins {
        set_up(&owner, &account1, &aptos_framework);
        assert!(comparator::is_equal(&comparator::compare(
            &current_amount_in(10000, key_of<USDC>()),
            &100
        )), current_amount_in(100, key_of<USDC>()));
    }

    //#[test(owner=@leizd_aptos_trove,account1=@0x111,aptos_framework=@aptos_framework)]
    //#[expected_failure(abort_code = 3)]
    //fun test_close_trove_below_min_cr(owner: signer, account1: signer) acquires Vault, Trove, TroveEventHandle, Statistics, SupportedCoins {
    //    set_up(&owner, &account1);
    //    let usdc_amt = 10000;
    //    // over minCR
    //    let want = usdc_amt * math64::pow(10, 8 - 6) * 110 / 110;
    //    open_trove<USDT>(&account1, 10000, 0);
    //    open_trove<USDC>(&account1, 10000, want);
    //    close_trove<USDC>(&account1);
    //}

    #[test(owner=@leizd_aptos_trove,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65537)]
    fun test_open_trove_before_add_supported_coin(owner: &signer, account: &signer) acquires Vault, Trove, TroveEventHandle, SupportedCoins {
        let owner_addr = signer::address_of(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account_addr);
        test_coin::init_usdc(owner);
        managed_coin::register<usdz::USDZ>(account);
        managed_coin::register<USDC>(account);
        managed_coin::mint<USDC>(owner, account_addr, 10000);

        initialize_internal(owner);
        price_oracle::initialize(owner);
        price_oracle::register_oracle_with_fixed_price<USDC>(owner, 1000000, 6, false);
        price_oracle::change_mode<USDC>(owner, 1);
        open_trove<USDC>(account, 10000, 1000);
    }

    //#[test(owner=@leizd_aptos_trove,account1=@0x111,aptos_framework=@aptos_framework)]
    //fun test_close_trove(owner: signer, account1: signer) acquires Vault, TroveEventHandle {
    //    //set_up(&owner, &account1);
    //    //open_trove<USDC>(&account1, 10000);
    //    ////close_trove<USDC>(&account1);
    //    //let account1_addr = signer::address_of(&account1);
    //    //assert!(coin::balance<USDC>(account1_addr) == 10000, 0);
    //    ////let trove = borrow_global<Trove>(account1_addr);
    //    ////assert!(coin::value(&trove.coin) == 0, 0);
    //}    

   //#[test(owner=@leizd_aptos_trove,account1=@0x111,aptos_framework=@aptos_framework)]
   //fun test_repay(owner: signer, account1: signer) acquires Trove, Vault, TroveEventHandle {
   //    set_up(&owner, &account1);
   //    open_trove<USDC>(&account1, 10000);
   //    repay<USDC>(&account1, 5000);
   //    let account1_addr = signer::address_of(&account1);
   //    assert!(coin::balance<USDC>(account1_addr) == 5000, 0);
   //    let trove = borrow_global<Trove>(account1_addr);
// //      assert!(coin::value(&trove.coin) == 5000, 0);
   //    // repay more
   //    repay<USDC>(&account1, 5000);
   //    assert!(coin::balance<USDC>(account1_addr) == 10000, 0);
   //    let trove2 = borrow_global<Trove>(account1_addr);
// //      as   sert!(coin::value(&trove2.coin) == 0, 0);
   //}

    #[test(owner=@leizd_aptos_trove,alice=@0x111,bob=@0x222,carol=@0x333,dave=@0x444,aptos_framework=@aptos_framework)]
    fun test_redeem(owner: &signer, alice: &signer, bob: &signer, carol: &signer, dave: &signer, aptos_framework: &signer) acquires SupportedCoins, Trove, TroveEventHandle, Vault {
        set_up(owner, alice, aptos_framework);
        set_up_account(owner, bob);
        set_up_account(owner, carol);
        set_up_account(owner, dave);
        let now = 1662125899730897;
        timestamp::update_global_time_for_test(now);
        let redeem_amount = 10000000000;
        usdz::mint_for_test(signer::address_of(dave), redeem_amount);
        let mid_borrow = USDC_AMT * math64::pow(10, 8 - 6) * 7 / 10;
        open_trove<USDC>(alice, USDC_AMT, mid_borrow);
        open_trove<USDC>(bob, USDC_AMT, mid_borrow + 1);
        open_trove<USDC>(carol, USDC_AMT, mid_borrow - 1);
        let one_minute = 60 * 1000 * 1000;
        timestamp::update_global_time_for_test(now + one_minute * 10);
        // if redeems 100000000 USDZ
        redeem<USDC>(dave, vector::singleton<address>(signer::address_of(bob)), redeem_amount);
        assert!(comparator::is_equal(&comparator::compare(
            &coin::balance<USDC>(signer::address_of(dave)),
        // then returns 100000000 USDC
            &(USDC_AMT + 100000000)
        )), coin::balance<USDC>(signer::address_of(dave)));
    }

    #[test(owner=@leizd_aptos_trove,alice=@0x111,bob=@0x222,carol=@0x333,dave=@0x444,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 4)]
    fun test_not_redeemable(owner: &signer, alice: &signer, bob: &signer, carol: &signer, dave: &signer, aptos_framework: &signer) acquires SupportedCoins, Trove, TroveEventHandle, Vault {
        set_up(owner, alice, aptos_framework);
        set_up_account(owner, bob);
        set_up_account(owner, carol);
        set_up_account(owner, dave);
        let redeem_amount = 1000 * 1000000;
        usdz::mint_for_test(signer::address_of(dave), redeem_amount);
        let mid_borrow = USDC_AMT * math64::pow(10, 8 - 6) * 5 / 10;
        open_trove<USDC>(alice, USDC_AMT, mid_borrow);
        open_trove<USDC>(bob, USDC_AMT, mid_borrow + 1000000);
        open_trove<USDC>(carol, USDC_AMT, mid_borrow - 1000000 * 100);
        assert!(!redeemable(signer::address_of(carol)), (collateral_ratio_of(signer::address_of(carol)) as u64));
        redeem<USDC>(dave, vector::singleton<address>(signer::address_of(carol)), redeem_amount);
    }

    #[test(owner=@leizd_aptos_trove,aptos_framework=@aptos_framework)]
    fun test_current_amount_in_usdz(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_usdc(owner);
        initialize(owner);
        initialize_oracle(owner);

        let usdc_amt = 12345678;
        let usdc_want = usdc_amt * math64::pow(10, 8 - 6);
        assert!(comparator::is_equal(&comparator::compare(
            &current_amount_in_usdz(usdc_amt, key_of<USDC>()),
            &usdc_want
        )), 0);
    }

    #[test_only]
    struct DummyCoin {}
    #[test(owner=@leizd_aptos_trove,aptos_framework=@aptos_framework)]
    fun test_current_amount_in_usdz__check_when_decimal_is_less_than_usdz(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        initialize_oracle(owner);
        let decimals: u8 = 3;
        test_coin::init_coin<DummyCoin>(owner, b"DUMMY", decimals);
        initialize_oracle_coin<DummyCoin>(owner, 1000, decimals);

        let expected = 100000 * math64::pow(10, (coin::decimals<usdz::USDZ>() - decimals as u64));
        assert!(current_amount_in_usdz(100000, key_of<DummyCoin>()) == expected, 0);
    }
    #[test(owner=@leizd_aptos_trove,aptos_framework=@aptos_framework)]
    fun test_current_amount_in_usdz__check_when_decimal_is_greater_than_usdz(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        initialize_oracle(owner);
        let decimals: u8 = 12;
        test_coin::init_coin<DummyCoin>(owner, b"DUMMY", decimals);
        price_oracle::register_oracle_with_fixed_price<DummyCoin>(owner, 1000000000000, decimals, false);
        price_oracle::change_mode<DummyCoin>(owner, 1);
        let expected = 100000 / math64::pow(10, (decimals - coin::decimals<usdz::USDZ>() as u64));
        assert!(current_amount_in_usdz(100000, key_of<DummyCoin>()) == expected, 0);
    }
    #[test(owner=@leizd_aptos_trove,aptos_framework=@aptos_framework)]
    fun test_current_amount_in_usdz__check_overflow__maximum_allowable_value(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_coin<DummyCoin>(owner, b"DUMMY", 8);
        initialize(owner);
        initialize_oracle(owner);
        price_oracle::register_oracle_with_fixed_price<DummyCoin>(owner, 100000000, 8, false);
        price_oracle::change_mode<DummyCoin>(owner, 1);

        let u64_max: u64 = 18446744073709551615;
        assert!(current_amount_in_usdz(u64_max, key_of<DummyCoin>()) == u64_max, 0);
    }
    #[test(owner=@leizd_aptos_trove,aptos_framework=@aptos_framework)]
    #[expected_failure]
    fun test_current_amount_in_usdz__check_overflow(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_coin<DummyCoin>(owner, b"DUMMY", 0);
        initialize(owner);
        initialize_oracle(owner);

        let u64_max: u64 = 18446744073709551615;
        current_amount_in_usdz(u64_max, key_of<DummyCoin>());
    }
}
