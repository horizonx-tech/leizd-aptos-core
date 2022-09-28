module leizd_aptos_treasury::treasury {

    use std::option::{Self,Option};
    use std::signer;
    use std::string::{String};
    use aptos_std::simple_map;
    use aptos_framework::coin;
    use aptos_framework::type_info;
    use leizd_aptos_common::coin_key;
    use leizd_aptos_common::permission;
    use leizd_aptos_trove::usdz::{USDZ};

    const EALREADY_INITIALIZED: u64 = 0;
    const ECOIN_UNSUPPORTED: u64 = 1;
    const EALREADY_ADDED: u64 = 2;

    struct Treasury<phantom C> has key {
        coin: coin::Coin<C>,
    }

    struct SupportedTreasuries has key {
        treasuries: simple_map::SimpleMap<String, address>, // key: 0x1::module_name::WBTC
    }

    public fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        assert!(!initialized(), EALREADY_INITIALIZED);

        let map = simple_map::create<String, address>();
        simple_map::add<String, address>(&mut map, type_info::type_name<USDZ>(), signer::address_of(owner));
        move_to(owner, SupportedTreasuries{
            treasuries: map
        });
        move_to(owner, Treasury<USDZ> {
            coin: coin::zero<USDZ>(),
        });
    }

    public fun initialized(): bool {
        exists<SupportedTreasuries>(permission::owner_address())
    }

    fun get_treasury_owner<C>(): Option<address> acquires SupportedTreasuries {
        let treasuries = borrow_global<SupportedTreasuries>(permission::owner_address()).treasuries;
        let treasury_key = coin_key::key<C>();
        if (simple_map::contains_key<String, address>(&treasuries, &treasury_key)) {
            return option::some<address>(*simple_map::borrow<String, address>(&treasuries, &treasury_key))
        };
        option::none<address>()
    }

    public fun add_coin<C>(owner: &signer) acquires SupportedTreasuries {
        assert!(!is_coin_supported<C>(), EALREADY_ADDED);
        move_to(owner, Treasury<C> {
            coin: coin::zero<C>(),
        });
        let treasuries = borrow_global_mut<SupportedTreasuries>(permission::owner_address());
        simple_map::add<String, address>(&mut treasuries.treasuries, coin_key::key<C>(), signer::address_of(owner));
    }

    public entry fun collect_fee<C>(coin: coin::Coin<C>) acquires Treasury, SupportedTreasuries {
        assert_coin_supported<C>();
        let treasury_ref = borrow_global_mut<Treasury<C>>(permission::owner_address());
        coin::merge<C>(&mut treasury_ref.coin, coin);
    }

    fun assert_coin_supported<C>() acquires SupportedTreasuries {
        assert!(is_coin_supported<C>(), ECOIN_UNSUPPORTED);
    }

    fun is_coin_supported<C>(): bool acquires SupportedTreasuries {
        let owner = get_treasury_owner<C>();
        option::is_some(&owner)
    }

    public entry fun withdraw_fee<C>(owner: &signer, amount: u64) acquires Treasury, SupportedTreasuries {
        assert_coin_supported<C>();
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);

        let treasury_ref = borrow_global_mut<Treasury<C>>(owner_address);
        let deposited = coin::extract(&mut treasury_ref.coin, amount);
        coin::deposit<C>(owner_address, deposited);
    }

    public fun balance<C>(): u64 acquires Treasury {
        let treasury_ref = borrow_global_mut<Treasury<C>>(permission::owner_address());
        coin::value<C>(&treasury_ref.coin)
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd_aptos_trove::usdz;
    #[test_only]
    use leizd_aptos_common::test_coin::{Self, WETH};
    #[test(owner = @leizd_aptos_treasury, account = @0x111)]
    fun test_end_to_end(owner: &signer, account: &signer) acquires Treasury, SupportedTreasuries {
        // prepares
        let owner_address = permission::owner_address();
        let account_address = signer::address_of(account);
        account::create_account_for_test(owner_address);
        account::create_account_for_test(account_address);
        test_coin::init_weth(owner);
        usdz::initialize_for_test(owner);
        managed_coin::register<USDZ>(owner);
        managed_coin::register<WETH>(account);
        managed_coin::register<USDZ>(account);
        managed_coin::mint<WETH>(owner, account_address, 1000);
        usdz::mint_for_test(account_address, 500);
        initialize(owner);
        add_coin<WETH>(owner);
        assert!(balance<WETH>() == 0, 0);
        assert!(balance<USDZ>() == 0, 0);

        collect_fee<WETH>(coin::withdraw<WETH>(account, 200));
        assert!(balance<WETH>() == 200, 0);
        assert!(balance<USDZ>() == 0, 0);
        assert!(coin::balance<WETH>(account_address) == 800, 0);
        assert!(coin::balance<USDZ>(account_address) == 500, 0);
        assert!(coin::balance<WETH>(owner_address) == 0, 0);
        assert!(coin::balance<USDZ>(owner_address) == 0, 0);

        collect_fee<USDZ>(coin::withdraw<USDZ>(account, 100));
        assert!(balance<WETH>() == 200, 0);
        assert!(balance<USDZ>() == 100, 0);
        assert!(coin::balance<WETH>(account_address) == 800, 0);
        assert!(coin::balance<USDZ>(account_address) == 400, 0);
        assert!(coin::balance<WETH>(owner_address) == 0, 0);
        assert!(coin::balance<USDZ>(owner_address) == 0, 0);

        withdraw_fee<WETH>(owner, 150);
        assert!(balance<WETH>() == 50, 0);
        assert!(balance<USDZ>() == 100, 0);
        assert!(coin::balance<WETH>(account_address) == 800, 0);
        assert!(coin::balance<USDZ>(account_address) == 400, 0);
        assert!(coin::balance<WETH>(owner_address) == 150, 0);
        assert!(coin::balance<USDZ>(owner_address) == 0, 0);

        withdraw_fee<USDZ>(owner, 75);
        assert!(balance<WETH>() == 50, 0);
        assert!(balance<USDZ>() == 25, 0);
        assert!(coin::balance<WETH>(account_address) == 800, 0);
        assert!(coin::balance<USDZ>(account_address) == 400, 0);
        assert!(coin::balance<WETH>(owner_address) == 150, 0);
        assert!(coin::balance<USDZ>(owner_address) == 75, 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_withdraw_asset_fee_with_not_owner(account: &signer) acquires Treasury, SupportedTreasuries {
        initialize(account);
        add_coin<WETH>(account);
        withdraw_fee<WETH>(account, 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_withdraw_shadow_fee_with_not_owner(account: &signer) acquires Treasury, SupportedTreasuries {
        initialize(account);
        add_coin<WETH>(account);
        withdraw_fee<WETH>(account, 0);
    }

    #[test(account = @0x1)]
    #[expected_failure(abort_code = 1)]
    fun test_initialize_by_not_owner(account: &signer) {
        initialize(account);
    }

    #[test(owner = @leizd_aptos_treasury)]
    #[expected_failure(abort_code = 0)]
    fun test_initialize_multiple_times(owner: &signer) {
        initialize(owner);
        initialize(owner);
    }

    #[test(owner = @leizd_aptos_treasury)]
    #[expected_failure(abort_code = 2)]
    fun test_add_coin_multiple_times(owner: &signer) acquires SupportedTreasuries{
        initialize(owner);
        add_coin<WETH>(owner);
        add_coin<WETH>(owner);
    }

}
