module leizd::pool_manager {

  use std::signer;
  use std::string::{String};
  use aptos_std::simple_map;
  use aptos_framework::type_info::{Self, TypeInfo};
  use leizd::asset_pool;
  use leizd::permission;

  struct PoolInfo has store {
    type_info: TypeInfo,
    holder: address
  }

  struct PoolList has key {
    infos: simple_map::SimpleMap<String, PoolInfo>, // key: type_name
  }

  public entry fun initialize(owner: &signer) {
    permission::assert_owner(signer::address_of(owner));
    move_to(owner, PoolList { infos: simple_map::create<String, PoolInfo>() });
  }

  public entry fun add_pool<C>(holder: &signer) acquires PoolList {
    asset_pool::init_pool<C>(holder);

    let pool_list = borrow_global_mut<PoolList>(permission::owner_address());
    let key = type_info::type_name<C>();
    simple_map::add<String, PoolInfo>(&mut pool_list.infos, key, PoolInfo {
      type_info: type_info::type_of<C>(),
      holder: signer::address_of(holder)
    });
  }

  #[test_only]
  use aptos_framework::account;
  #[test_only]
  use leizd::risk_factor;
  #[test_only]
  use leizd::test_coin::{Self, WETH, USDC};
  #[test(owner = @leizd)]
  fun test_initialize(owner: &signer) {
    initialize(owner);
    assert!(exists<PoolList>(signer::address_of(owner)), 0);
  }
  #[test(account = @0x111)]
  #[expected_failure(abort_code = 1)]
  fun test_initialize_with_not_owner(account: &signer) {
    initialize(account);
  }
  #[test(owner = @leizd)]
  fun test_add_pool_from_owner(owner: &signer) acquires PoolList {
    account::create_account_for_test(signer::address_of(owner));
    test_coin::init_weth(owner);
    test_coin::init_usdc(owner);
    risk_factor::initialize(owner);

    initialize(owner);
    add_pool<WETH>(owner);
  }
  #[test(owner = @leizd, account = @0x111)]
  fun test_add_pool_from_not_owner(owner: &signer, account: &signer) acquires PoolList {
    account::create_account_for_test(signer::address_of(owner));
    test_coin::init_usdc(owner);
    risk_factor::initialize(owner);

    initialize(owner);
    account::create_account_for_test(signer::address_of(account));
    add_pool<USDC>(account);
  }
}