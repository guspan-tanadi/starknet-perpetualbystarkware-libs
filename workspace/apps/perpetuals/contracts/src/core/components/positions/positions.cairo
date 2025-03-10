#[starknet::component]
pub(crate) mod Positions {
    use core::num::traits::{One, Zero};
    use core::panic_with_felt252;
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::introspection::src5::SRC5Component;
    use perpetuals::core::components::assets::AssetsComponent;
    use perpetuals::core::components::assets::AssetsComponent::InternalTrait as AssetsInternalTrait;
    use perpetuals::core::components::positions::errors::{
        ALREADY_INITIALIZED, CALLER_IS_NOT_OWNER_ACCOUNT, INVALID_ZERO_OWNER_ACCOUNT,
        INVALID_ZERO_PUBLIC_KEY, NO_OWNER_ACCOUNT, POSITION_ALREADY_EXISTS, POSITION_DOESNT_EXIST,
        POSITION_HAS_OWNER_ACCOUNT, SAME_PUBLIC_KEY, SET_POSITION_OWNER_EXPIRED,
        SET_PUBLIC_KEY_EXPIRED,
    };
    use perpetuals::core::components::positions::events;
    use perpetuals::core::components::positions::interface::IPositions;
    use perpetuals::core::core::Core::SNIP12MetadataImpl;
    use perpetuals::core::types::asset::AssetId;
    use perpetuals::core::types::asset::synthetic::SyntheticTrait;
    use perpetuals::core::types::balance::Balance;
    use perpetuals::core::types::funding::calculate_funding;
    use perpetuals::core::types::position::{
        POSITION_VERSION, Position, PositionId, PositionMutableTrait, PositionTrait,
    };
    use perpetuals::core::types::set_owner_account::SetOwnerAccountArgs;
    use perpetuals::core::types::set_public_key::SetPublicKeyArgs;
    use perpetuals::core::types::{Asset, PositionData, PositionDiff, UnchangedAssets};
    use perpetuals::core::value_risk_calculator::{
        PositionState, PositionTVTR, calculate_position_tvtr, evaluate_position,
    };
    use starknet::storage::{
        Map, Mutable, StoragePath, StoragePathEntry, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};
    use starkware_utils::components::nonce::NonceComponent;
    use starkware_utils::components::nonce::NonceComponent::InternalTrait as NonceInternal;
    use starkware_utils::components::pausable::PausableComponent;
    use starkware_utils::components::pausable::PausableComponent::InternalTrait as PausableInternal;
    use starkware_utils::components::request_approvals::RequestApprovalsComponent;
    use starkware_utils::components::request_approvals::RequestApprovalsComponent::InternalTrait as RequestApprovalsInternal;
    use starkware_utils::components::roles::RolesComponent;
    use starkware_utils::components::roles::RolesComponent::InternalTrait as RolesInternal;
    use starkware_utils::iterable_map::{
        IterableMapIntoIterImpl, IterableMapReadAccessImpl, IterableMapWriteAccessImpl,
    };
    use starkware_utils::span_utils::contains;
    use starkware_utils::types::time::time::Timestamp;
    use starkware_utils::types::{PublicKey, Signature};
    use starkware_utils::utils::{AddToStorage, validate_expiration};

    pub const FEE_POSITION: PositionId = PositionId { value: 0 };
    pub const INSURANCE_FUND_POSITION: PositionId = PositionId { value: 1 };


    #[storage]
    pub struct Storage {
        positions: Map<PositionId, Position>,
    }

    #[event]
    #[derive(Drop, PartialEq, starknet::Event)]
    pub enum Event {
        NewPosition: events::NewPosition,
        SetOwnerAccount: events::SetOwnerAccount,
        SetOwnerAccountRequest: events::SetOwnerAccountRequest,
        SetPublicKey: events::SetPublicKey,
        SetPublicKeyRequest: events::SetPublicKeyRequest,
    }

    #[embeddable_as(PositionsImpl)]
    impl Positions<
        TContractState,
        +HasComponent<TContractState>,
        +Drop<TContractState>,
        +AccessControlComponent::HasComponent<TContractState>,
        +SRC5Component::HasComponent<TContractState>,
        impl Assets: AssetsComponent::HasComponent<TContractState>,
        impl Nonce: NonceComponent::HasComponent<TContractState>,
        impl Pausable: PausableComponent::HasComponent<TContractState>,
        impl Roles: RolesComponent::HasComponent<TContractState>,
        impl RequestApprovals: RequestApprovalsComponent::HasComponent<TContractState>,
    > of IPositions<ComponentState<TContractState>> {
        fn get_position_assets(
            self: @ComponentState<TContractState>, position_id: PositionId,
        ) -> PositionData {
            let position = self.get_position_snapshot(:position_id);
            self.get_position_unchanged_assets(:position, position_diff: Default::default())
        }

        /// This function is primarily used as a view function—knowing the total value and/or
        /// total risk without context is unnecessary.
        fn get_position_tv_tr(
            self: @ComponentState<TContractState>, position_id: PositionId,
        ) -> PositionTVTR {
            let position = self.get_position_snapshot(:position_id);
            let position_data = self
                .get_position_unchanged_assets(:position, position_diff: Default::default());
            calculate_position_tvtr(:position_data)
        }

        /// This function is mostly used as view function - it's better to use the
        /// `evaluate_position_change` function as it gives all the information needed at the same
        /// cost.
        fn is_healthy(self: @ComponentState<TContractState>, position_id: PositionId) -> bool {
            let position = self.get_position_snapshot(:position_id);
            let position_state = self._get_position_state(:position);
            position_state == PositionState::Healthy
        }

        /// This function is mostly used as view function - it's better to use the
        /// `evaluate_position_change` function as it gives all the information needed at the same
        /// cost.
        fn is_liquidatable(self: @ComponentState<TContractState>, position_id: PositionId) -> bool {
            let position = self.get_position_snapshot(:position_id);
            let position_state = self._get_position_state(:position);
            position_state == PositionState::Liquidatable
                || position_state == PositionState::Deleveragable
        }

        /// This function is mostly used as view function - it's better to use the
        /// `evaluate_position_change` function as it gives all the information needed at the same
        /// cost.
        fn is_deleveragable(
            self: @ComponentState<TContractState>, position_id: PositionId,
        ) -> bool {
            let position = self.get_position_snapshot(:position_id);
            let position_state = self._get_position_state(:position);
            position_state == PositionState::Deleveragable
        }

        /// Adds a new position to the system.
        ///
        /// Validations:
        /// - The contract must not be paused.
        /// - The operator nonce must be valid.
        /// - The position does not exist.
        /// - The owner public key is non-zero.
        ///
        /// Execution:
        /// - Create a new position with the given `owner_public_key` and `owner_account`.
        /// - Emit a `NewPosition` event.
        ///
        /// The position can be initialized with `owner_account` that is zero (no owner account).
        /// This is to support the case where it doesn't have a L2 account.
        fn new_position(
            ref self: ComponentState<TContractState>,
            operator_nonce: u64,
            position_id: PositionId,
            owner_public_key: PublicKey,
            owner_account: ContractAddress,
        ) {
            get_dep_component!(@self, Pausable).assert_not_paused();
            self._validate_operator_flow(:operator_nonce);
            let mut position = self.positions.entry(position_id);
            assert(position.version.read().is_zero(), POSITION_ALREADY_EXISTS);
            assert(owner_public_key.is_non_zero(), INVALID_ZERO_PUBLIC_KEY);
            position.version.write(POSITION_VERSION);
            position.owner_public_key.write(owner_public_key);
            if owner_account.is_non_zero() {
                position.owner_account.write(Option::Some(owner_account));
            }
            self
                .emit(
                    events::NewPosition {
                        position_id: position_id,
                        owner_public_key: owner_public_key,
                        owner_account: owner_account,
                    },
                );
        }

        /// Registers a request to set the position's owner_account.
        ///
        /// Validations:
        /// - Validates the signature.
        /// - Validates the position exists.
        /// - Validates the caller is the new_owner_account.
        /// - Validates the request does not exist.
        ///
        /// Execution:
        /// - Registers the set owner account request.
        /// - Emits a `SetOwnerAccountRequest` event.
        fn set_owner_account_request(
            ref self: ComponentState<TContractState>,
            signature: Signature,
            position_id: PositionId,
            new_owner_account: ContractAddress,
            expiration: Timestamp,
        ) {
            let position = self.get_position_snapshot(:position_id);
            let owner_account = position.get_owner_account();
            assert(owner_account.is_none(), POSITION_HAS_OWNER_ACCOUNT);
            assert(new_owner_account.is_non_zero(), INVALID_ZERO_OWNER_ACCOUNT);
            let public_key = position.get_owner_public_key();
            let mut request_approvals = get_dep_component_mut!(ref self, RequestApprovals);
            let hash = request_approvals
                .register_approval(
                    :owner_account,
                    :public_key,
                    :signature,
                    args: SetOwnerAccountArgs {
                        position_id, public_key, new_owner_account, expiration,
                    },
                );
            self
                .emit(
                    events::SetOwnerAccountRequest {
                        position_id,
                        public_key,
                        new_owner_account,
                        expiration,
                        set_owner_account_hash: hash,
                    },
                );
        }


        /// Sets the owner of a position to a new account owner.
        ///
        /// Validations:
        /// - The contract must not be paused.
        /// - The caller must be the operator.
        /// - The operator nonce must be valid.
        /// - The expiration time has not passed.
        /// - The position has no account owner.
        /// - The signature is valid.
        fn set_owner_account(
            ref self: ComponentState<TContractState>,
            operator_nonce: u64,
            position_id: PositionId,
            new_owner_account: ContractAddress,
            expiration: Timestamp,
        ) {
            get_dep_component!(@self, Pausable).assert_not_paused();
            self._validate_operator_flow(:operator_nonce);
            validate_expiration(:expiration, err: SET_POSITION_OWNER_EXPIRED);
            let position = self.get_position_mut(:position_id);
            let public_key = position.get_owner_public_key();
            assert(position.get_owner_account().is_none(), POSITION_HAS_OWNER_ACCOUNT);
            let mut request_approvals = get_dep_component_mut!(ref self, RequestApprovals);
            let hash = request_approvals
                .consume_approved_request(
                    args: SetOwnerAccountArgs {
                        position_id, public_key, new_owner_account, expiration,
                    },
                    :public_key,
                );
            position.owner_account.write(Option::Some(new_owner_account));
            self
                .emit(
                    events::SetOwnerAccount {
                        position_id, public_key, new_owner_account, set_owner_account_hash: hash,
                    },
                );
        }

        /// Registers a request to set the position's public key.
        ///
        /// Validations:
        /// - Validates the signature.
        /// - Validates the position exists.
        /// - Validates the caller is the owner of the position.
        /// - Validates the request does not exist.
        ///
        /// Execution:
        /// - Registers the set public key request.
        /// - Emits a `SetPublicKeyRequest` event.
        fn set_public_key_request(
            ref self: ComponentState<TContractState>,
            signature: Signature,
            position_id: PositionId,
            new_public_key: PublicKey,
            expiration: Timestamp,
        ) {
            let position = self.get_position_snapshot(:position_id);
            let old_public_key = position.get_owner_public_key();
            assert(new_public_key != old_public_key, SAME_PUBLIC_KEY);
            let owner_account = position.get_owner_account();
            if let Option::Some(owner_account) = owner_account {
                assert(owner_account == get_caller_address(), CALLER_IS_NOT_OWNER_ACCOUNT);
            } else {
                panic_with_felt252(NO_OWNER_ACCOUNT);
            }
            let mut request_approvals = get_dep_component_mut!(ref self, RequestApprovals);
            let hash = request_approvals
                .register_approval(
                    :owner_account,
                    public_key: new_public_key,
                    :signature,
                    args: SetPublicKeyArgs {
                        position_id, old_public_key, new_public_key, expiration,
                    },
                );
            self
                .emit(
                    events::SetPublicKeyRequest {
                        position_id,
                        new_public_key,
                        old_public_key,
                        expiration,
                        set_public_key_request_hash: hash,
                    },
                );
        }

        /// Sets the position's public key.
        ///
        /// Validations:
        /// - The contract must not be paused.
        /// - The operator nonce must be valid.
        /// - The expiration time has not passed.
        /// - The position has an owner account.
        /// - The request has been registered.
        fn set_public_key(
            ref self: ComponentState<TContractState>,
            operator_nonce: u64,
            position_id: PositionId,
            new_public_key: PublicKey,
            expiration: Timestamp,
        ) {
            get_dep_component!(@self, Pausable).assert_not_paused();
            self._validate_operator_flow(:operator_nonce);
            validate_expiration(:expiration, err: SET_PUBLIC_KEY_EXPIRED);
            let position = self.get_position_mut(:position_id);
            let owner_account = position.get_owner_account();
            let old_public_key = position.get_owner_public_key();
            assert(owner_account.is_some(), NO_OWNER_ACCOUNT);
            let mut request_approvals = get_dep_component_mut!(ref self, RequestApprovals);
            let hash = request_approvals
                .consume_approved_request(
                    args: SetPublicKeyArgs {
                        position_id, old_public_key, new_public_key, expiration,
                    },
                    public_key: new_public_key,
                );
            position.owner_public_key.write(new_public_key);
            self
                .emit(
                    events::SetPublicKey {
                        position_id,
                        new_public_key,
                        old_public_key,
                        set_public_key_request_hash: hash,
                    },
                );
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState,
        +HasComponent<TContractState>,
        +Drop<TContractState>,
        +AccessControlComponent::HasComponent<TContractState>,
        +SRC5Component::HasComponent<TContractState>,
        impl Assets: AssetsComponent::HasComponent<TContractState>,
        impl Nonce: NonceComponent::HasComponent<TContractState>,
        impl Pausable: PausableComponent::HasComponent<TContractState>,
        impl Roles: RolesComponent::HasComponent<TContractState>,
        impl RequestApprovals: RequestApprovalsComponent::HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        fn initialize(
            ref self: ComponentState<TContractState>,
            fee_position_owner_public_key: PublicKey,
            insurance_fund_position_owner_public_key: PublicKey,
        ) {
            // Checks that the component has not been initialized yet.
            let fee_position = self.positions.entry(FEE_POSITION);
            assert(fee_position.get_owner_public_key().is_zero(), ALREADY_INITIALIZED);

            // Checks that the input public keys are non-zero.
            assert(fee_position_owner_public_key.is_non_zero(), INVALID_ZERO_PUBLIC_KEY);
            assert(insurance_fund_position_owner_public_key.is_non_zero(), INVALID_ZERO_PUBLIC_KEY);

            // Create fee positions.
            fee_position.version.write(POSITION_VERSION);
            fee_position.owner_public_key.write(fee_position_owner_public_key);

            let insurance_fund_position = self.positions.entry(INSURANCE_FUND_POSITION);
            insurance_fund_position.version.write(POSITION_VERSION);
            insurance_fund_position
                .owner_public_key
                .write(insurance_fund_position_owner_public_key);
        }

        fn apply_diff(
            ref self: ComponentState<TContractState>,
            position_id: PositionId,
            position_diff: PositionDiff,
        ) {
            if position_diff.collateral.is_none() && position_diff.synthetics.len().is_zero() {
                return;
            }
            let position_mut = self.get_position_mut(:position_id);
            if let Option::Some(balance_diff) = position_diff.collateral {
                position_mut.collateral_balance.write(balance_diff.after);
            }

            for diff in position_diff.synthetics {
                let synthetic_id = *diff.id;
                self
                    ._update_synthetic_balance_and_funding(
                        position: position_mut, :synthetic_id, new_balance: *diff.balance.after,
                    );
            };
        }

        fn get_position_snapshot(
            self: @ComponentState<TContractState>, position_id: PositionId,
        ) -> StoragePath<Position> {
            let position = self.positions.entry(position_id);
            assert(position.version.read().is_non_zero(), POSITION_DOESNT_EXIST);
            position
        }

        /// Returns the position at the given `position_id`.
        /// The function asserts that the position exists and has a non-zero version.
        fn get_position_mut(
            ref self: ComponentState<TContractState>, position_id: PositionId,
        ) -> StoragePath<Mutable<Position>> {
            let mut position = self.positions.entry(position_id);
            assert(position.version.read().is_non_zero(), POSITION_DOESNT_EXIST);
            position
        }

        fn get_synthetic_balance(
            self: @ComponentState<TContractState>,
            position: StoragePath<Position>,
            synthetic_id: AssetId,
        ) -> Balance {
            if let Option::Some(synthetic) = position.synthetic_assets.read(synthetic_id) {
                synthetic.balance
            } else {
                0_i64.into()
            }
        }

        fn get_collateral_provisional_balance(
            self: @ComponentState<TContractState>, position: StoragePath<Position>,
        ) -> Balance {
            let assets = get_dep_component!(self, Assets);
            let mut collateral_provisional_balance = position.collateral_balance.read();
            for (synthetic_id, synthetic) in position.synthetic_assets {
                if synthetic.balance.is_zero() {
                    continue;
                }
                let funding_index = assets.get_funding_index(synthetic_id);
                collateral_provisional_balance +=
                    calculate_funding(synthetic.funding_index, funding_index, synthetic.balance);
            }
            collateral_provisional_balance
        }

        /// Returns all assets from the position, excluding assets with zero balance
        /// and those included in `position_diff`.
        fn get_position_unchanged_assets(
            self: @ComponentState<TContractState>,
            position: StoragePath<Position>,
            position_diff: PositionDiff,
        ) -> UnchangedAssets {
            let mut position_data = array![];
            let assets = get_dep_component!(self, Assets);
            let collateral_id = assets.get_collateral_id();

            let mut synthetics_diff = array![];

            if position_diff.collateral.is_none() {
                let balance = self.get_collateral_provisional_balance(position);
                if balance.is_non_zero() {
                    position_data
                        .append(
                            Asset {
                                id: collateral_id,
                                balance,
                                price: One::one(),
                                risk_factor: Zero::zero(),
                            },
                        )
                }
            }
            for diff in position_diff.synthetics {
                synthetics_diff.append(*(diff.id));
            }

            for (synthetic_id, synthetic) in position.synthetic_assets {
                let balance = synthetic.balance;
                if balance.is_zero()
                    || contains(span: synthetics_diff.span(), element: synthetic_id) {
                    continue;
                }
                let price = assets.get_synthetic_price(synthetic_id);
                let risk_factor = assets.get_synthetic_risk_factor(synthetic_id, balance, price);
                position_data.append(Asset { id: synthetic_id, balance, price, risk_factor });
            }
            position_data.span()
        }
    }

    #[generate_trait]
    impl PrivateImpl<
        TContractState,
        +HasComponent<TContractState>,
        +Drop<TContractState>,
        +AccessControlComponent::HasComponent<TContractState>,
        +SRC5Component::HasComponent<TContractState>,
        impl Assets: AssetsComponent::HasComponent<TContractState>,
        impl Nonce: NonceComponent::HasComponent<TContractState>,
        impl Pausable: PausableComponent::HasComponent<TContractState>,
        impl Roles: RolesComponent::HasComponent<TContractState>,
        impl RequestApprovals: RequestApprovalsComponent::HasComponent<TContractState>,
    > of PrivateTrait<TContractState> {
        fn _validate_position_exists(
            self: @ComponentState<TContractState>, position_id: PositionId,
        ) {
            // get_position_snapshot asserts that the position exists and has a non-zero version.
            self.get_position_snapshot(:position_id);
        }

        /// Updates the synthetic balance and handles the funding mechanism.
        /// This function adjusts the main collateral balance of a position by applying funding
        /// costs or earnings based on the difference between the global funding index and the
        /// current funding index.
        ///
        /// The main collateral balance is updated using the following formula:
        /// main_collateral_balance += synthetic_balance * (global_funding_index - funding_index).
        /// After the adjustment, the `funding_index` is set to `global_funding_index`.
        ///
        /// Example:
        /// main_collateral_balance = 1000;
        /// synthetic_balance = 50;
        /// funding_index = 200;
        /// global_funding_index = 210;
        ///
        /// new_synthetic_balance = 300;
        ///
        /// After the update:
        /// main_collateral_balance = 1500; // 1000 + 50 * (210 - 200)
        /// synthetic_balance = 300;
        /// synthetic_funding_index = 210;
        ///
        fn _update_synthetic_balance_and_funding(
            ref self: ComponentState<TContractState>,
            position: StoragePath<Mutable<Position>>,
            synthetic_id: AssetId,
            new_balance: Balance,
        ) {
            let assets = get_dep_component!(@self, Assets);
            let global_funding_index = assets.get_funding_index(:synthetic_id);

            // Adjusts the main collateral balance accordingly:
            let mut collateral_balance = 0_i64.into();
            if let Option::Some(synthetic) = position.synthetic_assets.read(synthetic_id) {
                let old_balance = synthetic.balance;
                collateral_balance +=
                    calculate_funding(
                        old_funding_index: synthetic.funding_index,
                        new_funding_index: global_funding_index,
                        balance: old_balance,
                    );
            }
            position.collateral_balance.add_and_write(collateral_balance);

            // Updates the synthetic balance and funding index:
            let synthetic_asset = SyntheticTrait::asset(
                balance: new_balance, funding_index: global_funding_index,
            );
            position.synthetic_assets.write(synthetic_id, synthetic_asset);
        }

        fn _get_position_state(
            self: @ComponentState<TContractState>, position: StoragePath<Position>,
        ) -> PositionState {
            let position_diff = Default::default();
            let position_data = self.get_position_unchanged_assets(:position, :position_diff);

            let position_change_result = evaluate_position(:position_data);
            position_change_result.position_state_after_change
        }

        fn _validate_operator_flow(ref self: ComponentState<TContractState>, operator_nonce: u64) {
            get_dep_component!(@self, Roles).only_operator();
            let mut nonce = get_dep_component_mut!(ref self, Nonce);
            nonce.use_checked_nonce(nonce: operator_nonce);
        }
    }
}
