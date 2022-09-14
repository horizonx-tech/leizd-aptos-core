module leizd::pool_manager {

  use std::vector;
  use std::signer;
  use aptos_framework::type_info::{TypeInfo};
  use leizd::permission;

  struct PoolInfo has store {
    pool_type_info: TypeInfo,
    holder: address
  }

  struct PoolManager has key {
    infos: vector<PoolInfo>,
  }

  public entry fun initialize(owner: &signer) {
    permission::assert_owner(signer::address_of(owner));
    move_to(owner, PoolManager { infos: vector::empty<PoolInfo>() });
  }

  #[test(owner = @leizd)]
  fun test_initialize(owner: &signer) {
    initialize(owner);
    assert!(exists<PoolManager>(signer::address_of(owner)), 0);
  }
}