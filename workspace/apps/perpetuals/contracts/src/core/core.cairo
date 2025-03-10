#[starknet::contract]
pub mod Core {
    use core::num::traits::Zero;
    use core::panic_with_felt252;
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::token::erc20::interface::IERC20DispatcherTrait;
    use openzeppelin::utils::snip12::SNIP12Metadata;
    use perpetuals::core::components::assets::AssetsComponent;
    use perpetuals::core::components::assets::AssetsComponent::InternalTrait as AssetsInternal;
    use perpetuals::core::components::operator_nonce::OperatorNonceComponent;
    use perpetuals::core::components::operator_nonce::OperatorNonceComponent::InternalTrait as OperatorNonceInternal;
    use perpetuals::core::components::positions::Positions;
    use perpetuals::core::components::positions::Positions::{
        FEE_POSITION, INSURANCE_FUND_POSITION, InternalTrait as PositionsInternalTrait,
    };
    use perpetuals::core::errors::{
        CANT_DELEVERAGE_PENDING_ASSET, CANT_LIQUIDATE_IF_POSITION, CANT_TRADE_WITH_FEE_POSITION,
        DIFFERENT_BASE_ASSET_IDS, INVALID_ACTUAL_BASE_SIGN, INVALID_ACTUAL_QUOTE_SIGN,
        INVALID_AMOUNT_SIGN, INVALID_DELEVERAGE_BASE_CHANGE, INVALID_NON_SYNTHETIC_ASSET,
        INVALID_QUOTE_AMOUNT_SIGN, INVALID_SAME_POSITIONS, INVALID_ZERO_AMOUNT,
        QUOTE_ASSET_ID_NOT_COLLATERAL, TRANSFER_EXPIRED, WITHDRAW_EXPIRED, fulfillment_exceeded_err,
        illegal_zero_fee, order_expired_err,
    };
    use perpetuals::core::events;
    use perpetuals::core::interface::ICore;
    use perpetuals::core::types::asset::{AssetId, AssetStatus};
    use perpetuals::core::types::balance::Balance;
    use perpetuals::core::types::order::{Order, OrderTrait};
    use perpetuals::core::types::position::{Position, PositionId, PositionTrait};
    use perpetuals::core::types::transfer::TransferArgs;
    use perpetuals::core::types::withdraw::WithdrawArgs;
    use perpetuals::core::types::{AssetDiff, BalanceDiff, PositionDiff};
    use perpetuals::core::value_risk_calculator::{
        deleveraged_position_validations, liquidated_position_validations,
        validate_position_is_healthy_or_healthier,
    };
    use starknet::ContractAddress;
    use starknet::event::EventEmitter;
    use starknet::storage::{
        Map, StoragePath, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starkware_utils::components::deposit::Deposit;
    use starkware_utils::components::deposit::Deposit::InternalTrait as DepositInternal;
    use starkware_utils::components::pausable::PausableComponent;
    use starkware_utils::components::pausable::PausableComponent::InternalTrait as PausableInternal;
    use starkware_utils::components::replaceability::ReplaceabilityComponent;
    use starkware_utils::components::replaceability::ReplaceabilityComponent::InternalReplaceabilityTrait;
    use starkware_utils::components::request_approvals::RequestApprovalsComponent;
    use starkware_utils::components::request_approvals::RequestApprovalsComponent::InternalTrait as RequestApprovalsInternal;
    use starkware_utils::components::roles::RolesComponent;
    use starkware_utils::components::roles::RolesComponent::InternalTrait as RolesInternal;
    use starkware_utils::errors::assert_with_byte_array;
    use starkware_utils::math::abs::Abs;
    use starkware_utils::math::utils::have_same_sign;
    use starkware_utils::message_hash::OffchainMessageHash;
    use starkware_utils::types::time::time::{Time, TimeDelta, Timestamp};
    use starkware_utils::types::{HashType, PublicKey, Signature};
    use starkware_utils::utils::{validate_expiration, validate_stark_signature};

    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: OperatorNonceComponent, storage: operator_nonce, event: OperatorNonceEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: ReplaceabilityComponent, storage: replaceability, event: ReplaceabilityEvent);
    component!(path: RolesComponent, storage: roles, event: RolesEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: AssetsComponent, storage: assets, event: AssetsEvent);
    component!(path: Deposit, storage: deposits, event: DepositEvent);
    component!(
        path: RequestApprovalsComponent, storage: request_approvals, event: RequestApprovalsEvent,
    );
    component!(path: Positions, storage: positions, event: PositionsEvent);

    #[abi(embed_v0)]
    impl OperatorNonceImpl =
        OperatorNonceComponent::OperatorNonceImpl<ContractState>;

    #[abi(embed_v0)]
    impl DepositImpl = Deposit::DepositImpl<ContractState>;

    #[abi(embed_v0)]
    impl RequestApprovalsImpl =
        RequestApprovalsComponent::RequestApprovalsImpl<ContractState>;

    #[abi(embed_v0)]
    impl AssetsImpl = AssetsComponent::AssetsImpl<ContractState>;

    #[abi(embed_v0)]
    impl ReplaceabilityImpl =
        ReplaceabilityComponent::ReplaceabilityImpl<ContractState>;

    #[abi(embed_v0)]
    impl RolesImpl = RolesComponent::RolesImpl<ContractState>;

    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;

    #[abi(embed_v0)]
    impl PositionsImpl = Positions::PositionsImpl<ContractState>;

    const NAME: felt252 = 'Perpetuals';
    const VERSION: felt252 = 'v0';

    /// Required for hash computation.
    pub impl SNIP12MetadataImpl of SNIP12Metadata {
        fn name() -> felt252 {
            NAME
        }
        fn version() -> felt252 {
            VERSION
        }
    }

    #[storage]
    struct Storage {
        // Order hash to fulfilled absolute base amount.
        fulfillment: Map<HashType, u64>,
        // --- Components ---
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        operator_nonce: OperatorNonceComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        pub replaceability: ReplaceabilityComponent::Storage,
        #[substorage(v0)]
        pub roles: RolesComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        pub assets: AssetsComponent::Storage,
        #[substorage(v0)]
        pub deposits: Deposit::Storage,
        #[substorage(v0)]
        pub request_approvals: RequestApprovalsComponent::Storage,
        #[substorage(v0)]
        pub positions: Positions::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        OperatorNonceEvent: OperatorNonceComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        ReplaceabilityEvent: ReplaceabilityComponent::Event,
        #[flat]
        RolesEvent: RolesComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        AssetsEvent: AssetsComponent::Event,
        #[flat]
        DepositEvent: Deposit::Event,
        #[flat]
        RequestApprovalsEvent: RequestApprovalsComponent::Event,
        #[flat]
        PositionsEvent: Positions::Event,
        Deleverage: events::Deleverage,
        Liquidate: events::Liquidate,
        Trade: events::Trade,
        Transfer: events::Transfer,
        TransferRequest: events::TransferRequest,
        Withdraw: events::Withdraw,
        WithdrawRequest: events::WithdrawRequest,
    }

    #[constructor]
    pub fn constructor(
        ref self: ContractState,
        governance_admin: ContractAddress,
        upgrade_delay: u64,
        max_price_interval: TimeDelta,
        max_funding_interval: TimeDelta,
        max_funding_rate: u32,
        max_oracle_price_validity: TimeDelta,
        cancel_delay: TimeDelta,
        fee_position_owner_public_key: PublicKey,
        insurance_fund_position_owner_public_key: PublicKey,
    ) {
        self.roles.initialize(:governance_admin);
        self.replaceability.initialize(:upgrade_delay);
        self
            .assets
            .initialize(
                :max_price_interval,
                :max_funding_interval,
                :max_funding_rate,
                :max_oracle_price_validity,
            );
        self.deposits.initialize(:cancel_delay);
        self
            .positions
            .initialize(:fee_position_owner_public_key, :insurance_fund_position_owner_public_key);
    }

    #[abi(embed_v0)]
    pub impl CoreImpl of ICore<ContractState> {
        /// Process deposit a collateral amount from the 'depositing_address' to a given position.
        ///
        /// Validations:
        /// - Only the operator can call this function.
        /// - The contract must not be paused.
        /// - The `operator_nonce` must be valid.
        /// - The `expiration` time has not passed.
        /// - The collateral asset exists in the system.
        /// - The collateral asset is active.
        /// - The funding validation interval has not passed since the last funding tick.
        /// - The prices of all assets in the system are valid.
        /// - The deposit message has not been fulfilled.
        /// - A fact was registered for the deposit message.
        /// - If position exists, validate the owner_public_key and owner_account are the same.
        ///
        /// Execution:
        /// - Transfer the collateral `amount` to the position from the pending deposits.
        /// - Update the position's collateral balance.
        /// - Mark the deposit message as fulfilled.
        fn process_deposit(
            ref self: ContractState,
            operator_nonce: u64,
            depositor: ContractAddress,
            position_id: PositionId,
            amount: u64,
            salt: felt252,
        ) {
            /// Validations:
            self.pausable.assert_not_paused();
            self.operator_nonce.use_checked_nonce(:operator_nonce);
            self.assets.validate_assets_integrity();

            /// Execution - Deposit:
            let collateral_id = self.assets.get_collateral_id();
            self
                .deposits
                .process_deposit(
                    :depositor,
                    beneficiary: position_id.into(),
                    asset_id: collateral_id.into(),
                    quantized_amount: amount.into(),
                    :salt,
                );
            let position = self.positions.get_position_snapshot(:position_id);
            let position_diff = self
                ._create_collateral_position_diff(:position, diff: amount.into());
            self.positions.apply_diff(:position_id, :position_diff);
        }

        /// Requests a withdrawal of a collateral amount from a position to a `recipient`.
        ///
        /// Validations:
        /// - Validates the signature.
        /// - Validates the position exists.
        /// - Validates the request does not exist.
        /// - Validates the owner account is the caller.
        ///
        /// Execution:
        /// - Registers the withdraw request.
        /// - Emits a `WithdrawRequest` event.
        fn withdraw_request(
            ref self: ContractState,
            signature: Signature,
            recipient: ContractAddress,
            position_id: PositionId,
            amount: u64,
            expiration: Timestamp,
            salt: felt252,
        ) {
            let position = self.positions.get_position_snapshot(:position_id);
            let collateral_id = self.assets.get_collateral_id();
            assert(amount.is_non_zero(), INVALID_ZERO_AMOUNT);
            let hash = self
                .request_approvals
                .register_approval(
                    owner_account: position.get_owner_account(),
                    public_key: position.get_owner_public_key(),
                    :signature,
                    args: WithdrawArgs {
                        position_id, salt, expiration, collateral_id, amount, recipient,
                    },
                );
            self
                .emit(
                    events::WithdrawRequest {
                        position_id,
                        recipient,
                        collateral_id,
                        amount,
                        expiration,
                        withdraw_request_hash: hash,
                    },
                );
        }

        /// Withdraw collateral `amount` from the a position to `recipient`.
        ///
        /// Validations:
        /// - Only the operator can call this function.
        /// - The contract must not be paused.
        /// - The `operator_nonce` must be valid.
        /// - The `expiration` time has not passed.
        /// - The collateral asset exists in the system.
        /// - The collateral asset is active.
        /// - The funding validation interval has not passed since the last funding tick.
        /// - The prices of all assets in the system are valid.
        /// - The withdrawal message has not been fulfilled.
        /// - A fact was registered for the withdraw message.
        /// - Validate the position is healthy after the withdraw.
        ///
        /// Execution:
        /// - Transfer the collateral `amount` to the `recipient`.
        /// - Update the position's collateral balance.
        /// - Mark the withdrawal message as fulfilled.
        fn withdraw(
            ref self: ContractState,
            operator_nonce: u64,
            recipient: ContractAddress,
            position_id: PositionId,
            amount: u64,
            expiration: Timestamp,
            salt: felt252,
        ) {
            self.pausable.assert_not_paused();
            self.operator_nonce.use_checked_nonce(:operator_nonce);
            self.assets.validate_assets_integrity();
            validate_expiration(expiration: expiration, err: WITHDRAW_EXPIRED);
            let collateral_id = self.assets.get_collateral_id();
            let position = self.positions.get_position_snapshot(:position_id);
            let hash = self
                .request_approvals
                .consume_approved_request(
                    args: WithdrawArgs {
                        position_id, salt, expiration, collateral_id, amount, recipient,
                    },
                    public_key: position.get_owner_public_key(),
                );

            /// Validations - Fundamentals:
            let position = self.positions.get_position_snapshot(:position_id);
            let position_diff = self
                ._create_collateral_position_diff(:position, diff: -(amount.into()));
            self._validate_healthy_or_healthier_position(:position_id, :position, :position_diff);

            self.positions.apply_diff(:position_id, :position_diff);
            let token_contract = self.assets.get_collateral_token_contract();
            let quantum = self.assets.get_collateral_quantum();
            let withdraw_unquantized_amount = quantum * amount;
            token_contract.transfer(:recipient, amount: withdraw_unquantized_amount.into());

            self
                .emit(
                    events::Withdraw {
                        position_id,
                        recipient,
                        collateral_id,
                        amount,
                        expiration,
                        withdraw_request_hash: hash,
                    },
                );
        }

        /// Executes a transfer request.
        ///
        /// Validations:
        /// - Validates the position exists.
        /// - Validates the request does not exist.
        /// - If the position has an owner account, validate that the caller is the position owner
        /// account.
        /// - Validates the signature.
        ///
        /// Execution:
        /// - Registers the transfer request.
        /// - Emits a `TransferRequest` event.
        fn transfer_request(
            ref self: ContractState,
            signature: Signature,
            recipient: PositionId,
            position_id: PositionId,
            amount: u64,
            expiration: Timestamp,
            salt: felt252,
        ) {
            let position = self.positions.get_position_snapshot(:position_id);
            let collateral_id = self.assets.get_collateral_id();
            assert(amount.is_non_zero(), INVALID_ZERO_AMOUNT);
            let hash = self
                .request_approvals
                .register_approval(
                    owner_account: position.get_owner_account(),
                    public_key: position.get_owner_public_key(),
                    :signature,
                    args: TransferArgs {
                        position_id, recipient, salt, expiration, collateral_id, amount,
                    },
                );
            self
                .emit(
                    events::TransferRequest {
                        position_id,
                        recipient,
                        collateral_id,
                        amount,
                        expiration,
                        transfer_request_hash: hash,
                    },
                );
        }

        /// Executes a transfer.
        ///
        /// Validations:
        /// - The contract must not be paused.
        /// - Performs operator flow validations [`_validate_operator_flow`].
        /// - Validates both the sender and recipient positions exist.
        /// - Ensures the amount is positive.
        /// - Validates the expiration time.
        /// - Validates request approval.
        ///
        /// Execution:
        /// - Adjust collateral balances.
        /// - Validates the sender position is healthy or healthier after the execution.
        fn transfer(
            ref self: ContractState,
            operator_nonce: u64,
            recipient: PositionId,
            position_id: PositionId,
            amount: u64,
            expiration: Timestamp,
            salt: felt252,
        ) {
            self.pausable.assert_not_paused();
            self.operator_nonce.use_checked_nonce(:operator_nonce);
            self.assets.validate_assets_integrity();
            validate_expiration(:expiration, err: TRANSFER_EXPIRED);
            assert(recipient != position_id, INVALID_SAME_POSITIONS);
            let position = self.positions.get_position_snapshot(:position_id);
            let collateral_id = self.assets.get_collateral_id();
            let hash = self
                .request_approvals
                .consume_approved_request(
                    args: TransferArgs {
                        recipient, position_id, collateral_id, amount, expiration, salt,
                    },
                    public_key: position.get_owner_public_key(),
                );

            self._execute_transfer(:recipient, :position_id, :collateral_id, :amount);

            self
                .emit(
                    events::Transfer {
                        recipient,
                        position_id,
                        collateral_id,
                        amount,
                        expiration,
                        transfer_request_hash: hash,
                    },
                );
        }

        /// Executes a trade between two orders (Order A and Order B).
        ///
        /// Validations:
        /// - The contract must not be paused.
        /// - Performs operator flow validations [`_validate_operator_flow`].
        /// - Validates signatures for both orders using the public keys of their respective owners.
        /// - Ensures the fee amounts in both orders are positive.
        /// - Validates that the base and quote asset types match between the two orders.
        /// - Verifies the signs of amounts:
        ///   - Ensures the sign of amounts in each order is consistent.
        ///   - Ensures the signs between Order A and Order B amounts are opposite where required.
        /// - Ensures the order fulfillment amounts do not exceed their respective limits.
        /// - Validates that the fee ratio does not increase.
        /// - Ensures the base-to-quote amount ratio does not decrease.
        ///
        /// Execution:
        /// - Subtract the fees from each position's collateral.
        /// - Add the fees to the `fee_position`.
        /// - Update Order A's position and Order B's position, based on `actual_amount_base`.
        /// - Adjust collateral balances.
        /// - Perform fundamental validation for both positions after the execution.
        /// - Update order fulfillment.
        fn trade(
            ref self: ContractState,
            operator_nonce: u64,
            signature_a: Signature,
            signature_b: Signature,
            order_a: Order,
            order_b: Order,
            actual_amount_base_a: i64,
            actual_amount_quote_a: i64,
            actual_fee_a: u64,
            actual_fee_b: u64,
        ) {
            self.pausable.assert_not_paused();
            self.operator_nonce.use_checked_nonce(:operator_nonce);
            self.assets.validate_assets_integrity();

            let position_id_a = order_a.position_id;
            let position_id_b = order_b.position_id;

            let position_a = self.positions.get_position_snapshot(position_id_a);
            let position_b = self.positions.get_position_snapshot(position_id_b);

            // Signatures validation:
            let hash_a = self
                ._validate_order_signature(
                    position: position_a, order: order_a, signature: signature_a,
                );
            let hash_b = self
                ._validate_order_signature(
                    position: position_b, order: order_b, signature: signature_b,
                );

            self
                ._validate_trade(
                    :order_a,
                    :order_b,
                    :actual_amount_base_a,
                    :actual_amount_quote_a,
                    :actual_fee_a,
                    :actual_fee_b,
                );

            // Validate and update fulfillments.
            self
                ._update_fulfillment(
                    position_id: position_id_a,
                    hash: hash_a,
                    order_base_amount: order_a.base_amount,
                    actual_base_amount: actual_amount_base_a,
                );

            self
                ._update_fulfillment(
                    position_id: position_id_b,
                    hash: hash_b,
                    order_base_amount: order_b.base_amount,
                    // Passing the negative of actual amounts to `order_b` as it is linked to
                    // `order_a`.
                    actual_base_amount: -actual_amount_base_a,
                );

            /// Positions' Diffs:
            let position_diff_a = self
                ._create_position_diff_from_asset_amounts(
                    position: position_a,
                    effective_quote: actual_amount_quote_a.into() - actual_fee_a.into(),
                    base_id: order_a.base_asset_id,
                    base_amount: actual_amount_base_a.into(),
                );
            let position_diff_b = self
                ._create_position_diff_from_asset_amounts(
                    position: position_b,
                    // Passing the negative of actual amounts to order_b as it is linked to order_a.
                    effective_quote: -actual_amount_quote_a.into() - actual_fee_b.into(),
                    base_id: order_b.base_asset_id,
                    base_amount: -actual_amount_base_a.into(),
                );

            // Assuming fee_asset_id is the same for both orders.
            let fee_position_diff = self
                ._create_collateral_position_diff(
                    position: self.positions.get_position_snapshot(FEE_POSITION),
                    diff: (actual_fee_a + actual_fee_b).into(),
                );

            /// Validations - Fundamentals:
            self
                ._validate_healthy_or_healthier_position(
                    position_id: order_a.position_id,
                    position: position_a,
                    position_diff: position_diff_a,
                );
            self
                ._validate_healthy_or_healthier_position(
                    position_id: order_b.position_id,
                    position: position_b,
                    position_diff: position_diff_b,
                );

            // Apply Diffs.
            self
                .positions
                .apply_diff(position_id: order_a.position_id, position_diff: position_diff_a);

            self
                .positions
                .apply_diff(position_id: order_b.position_id, position_diff: position_diff_b);

            self.positions.apply_diff(position_id: FEE_POSITION, position_diff: fee_position_diff);

            self
                .emit(
                    events::Trade {
                        order_a_position_id: position_id_a,
                        order_a_base_asset_id: order_a.base_asset_id,
                        order_a_base_amount: order_a.base_amount,
                        order_a_quote_asset_id: order_a.quote_asset_id,
                        order_a_quote_amount: order_a.quote_amount,
                        fee_a_asset_id: order_a.fee_asset_id,
                        fee_a_amount: order_a.fee_amount,
                        order_b_position_id: position_id_b,
                        order_b_base_asset_id: order_b.base_asset_id,
                        order_b_base_amount: order_b.base_amount,
                        order_b_quote_asset_id: order_b.quote_asset_id,
                        order_b_quote_amount: order_b.quote_amount,
                        fee_b_asset_id: order_b.fee_asset_id,
                        fee_b_amount: order_b.fee_amount,
                        actual_amount_base_a,
                        actual_amount_quote_a,
                        actual_fee_a,
                        actual_fee_b,
                        order_a_hash: hash_a,
                        order_b_hash: hash_b,
                    },
                );
        }

        /// Executes a liquidate of a user position with liquidator order.
        ///
        /// Validations:
        /// - The contract must not be paused.
        /// - Performs operator flow validations [`_validate_operator_flow`].
        /// - Validates signatures for liquidator order using the public keys of it owner.
        /// - Ensures the fee amounts are positive.
        /// - Validates that the base and quote asset types match between the liquidator and
        /// liquidated orders.
        /// - Verifies the signs of amounts:
        ///   - Ensures the sign of amounts in each order is consistent.
        ///   - Ensures the signs between liquidated order and liquidator order amount are opposite.
        /// - Ensures the liquidator order fulfillment amount do not exceed its limit.
        /// - Validates that the fee ratio does not increase.
        /// - Ensures the base-to-quote amount ratio does not decrease.
        /// - Validates liquidated position is liquidatable.
        ///
        /// Execution:
        /// - Subtract the fees from each position's collateral.
        /// - Add the fees to the `fee_position`.
        /// - Update orders' position, based on `actual_amount_base`.
        /// - Adjust collateral balances.
        /// - Perform fundamental validation for both positions after the execution.
        /// - Update liquidator order fulfillment.
        fn liquidate(
            ref self: ContractState,
            operator_nonce: u64,
            liquidator_signature: Signature,
            liquidated_position_id: PositionId,
            liquidator_order: Order,
            actual_amount_base_liquidated: i64,
            actual_amount_quote_liquidated: i64,
            actual_liquidator_fee: u64,
            fee_amount: u64,
        ) {
            /// Validations:
            self.pausable.assert_not_paused();
            self.operator_nonce.use_checked_nonce(:operator_nonce);
            self.assets.validate_assets_integrity();

            let liquidator_position_id = liquidator_order.position_id;
            let liquidator_position = self.positions.get_position_snapshot(liquidator_position_id);

            // Signatures validation:
            let liquidator_order_hash = self
                ._validate_order_signature(
                    position: liquidator_position,
                    order: liquidator_order,
                    signature: liquidator_signature,
                );

            let collateral_id = self.assets.get_collateral_id();
            let liquidated_order = Order {
                position_id: liquidated_position_id,
                base_asset_id: liquidator_order.base_asset_id,
                base_amount: actual_amount_base_liquidated,
                quote_asset_id: liquidator_order.quote_asset_id,
                quote_amount: actual_amount_quote_liquidated,
                fee_asset_id: liquidator_order.fee_asset_id,
                fee_amount,
                // Dummy values needed to initialize the struct and pass validation.
                salt: Zero::zero(),
                expiration: Time::now(),
            };

            // Validations.
            self
                ._validate_trade(
                    order_a: liquidated_order,
                    order_b: liquidator_order,
                    actual_amount_base_a: actual_amount_base_liquidated,
                    actual_amount_quote_a: actual_amount_quote_liquidated,
                    actual_fee_a: fee_amount,
                    actual_fee_b: actual_liquidator_fee,
                );

            assert(liquidated_position_id != INSURANCE_FUND_POSITION, CANT_LIQUIDATE_IF_POSITION);
            // In case of liquidation of insurance fund, the liquidator fee should be zero.
            assert_with_byte_array(
                liquidator_order.position_id != INSURANCE_FUND_POSITION || fee_amount.is_zero(),
                illegal_zero_fee(),
            );

            // Validate and update fulfillment.
            self
                ._update_fulfillment(
                    position_id: liquidator_position_id,
                    hash: liquidator_order_hash,
                    order_base_amount: liquidator_order.base_amount,
                    // Passing the negative of actual amounts to `liquidator_order` as it is linked
                    // to liquidated_order.
                    actual_base_amount: -actual_amount_base_liquidated,
                );

            /// Execution:
            let liquidated_position_diff = self
                ._create_position_diff_from_asset_amounts(
                    position: self
                        .positions
                        .get_position_snapshot(position_id: liquidated_order.position_id),
                    effective_quote: actual_amount_quote_liquidated.into() - fee_amount.into(),
                    base_id: liquidated_order.base_asset_id,
                    base_amount: actual_amount_base_liquidated.into(),
                );
            let liquidator_position_diff = self
                ._create_position_diff_from_asset_amounts(
                    position: liquidator_position,
                    // Passing the negative of actual amounts to order_b as it is linked to order_a.
                    effective_quote: -actual_amount_quote_liquidated.into()
                        - actual_liquidator_fee.into(),
                    base_id: liquidator_order.base_asset_id,
                    base_amount: -actual_amount_base_liquidated.into(),
                );
            let insurance_position_diff = self
                ._create_collateral_position_diff(
                    position: self.positions.get_position_snapshot(INSURANCE_FUND_POSITION),
                    diff: fee_amount.into(),
                );
            let fee_position_diff = self
                ._create_collateral_position_diff(
                    position: self.positions.get_position_snapshot(FEE_POSITION),
                    diff: actual_liquidator_fee.into(),
                );

            let liquidated_position = self
                .positions
                .get_position_snapshot(position_id: liquidated_position_id);
            let liquidator_position = self
                .positions
                .get_position_snapshot(position_id: liquidator_position_id);

            /// Validations - Fundamentals:
            self
                ._validate_liquidated_position(
                    position_id: liquidated_position_id,
                    position: liquidated_position,
                    position_diff: liquidated_position_diff,
                );
            self
                ._validate_healthy_or_healthier_position(
                    position_id: liquidator_position_id,
                    position: liquidator_position,
                    position_diff: liquidator_position_diff,
                );

            // Apply Diffs.
            self
                .positions
                .apply_diff(
                    position_id: liquidated_position_id, position_diff: liquidated_position_diff,
                );

            self
                .positions
                .apply_diff(
                    position_id: liquidator_order.position_id,
                    position_diff: liquidator_position_diff,
                );

            self.positions.apply_diff(position_id: FEE_POSITION, position_diff: fee_position_diff);

            self
                .positions
                .apply_diff(
                    position_id: INSURANCE_FUND_POSITION, position_diff: insurance_position_diff,
                );

            self
                .emit(
                    events::Liquidate {
                        liquidated_position_id,
                        liquidator_order_position_id: liquidator_position_id,
                        liquidator_order_base_asset_id: liquidator_order.base_asset_id,
                        liquidator_order_base_amount: liquidator_order.base_amount,
                        liquidator_order_quote_asset_id: liquidator_order.quote_asset_id,
                        liquidator_order_quote_amount: liquidator_order.quote_amount,
                        liquidator_order_fee_asset_id: liquidator_order.fee_asset_id,
                        liquidator_order_fee_amount: liquidator_order.fee_amount,
                        actual_amount_base_liquidated,
                        actual_amount_quote_liquidated,
                        actual_liquidator_fee,
                        insurance_fund_fee_asset_id: collateral_id,
                        insurance_fund_fee_amount: fee_amount,
                        liquidator_order_hash: liquidator_order_hash,
                    },
                );
        }

        /// Executes a deleverage of a user position with a deleverager position.
        ///
        /// Validations:
        /// - The contract must not be paused.
        /// - Performs operator flow validations [`_validate_operator_flow`].
        /// - Verifies the signs of amounts:
        ///   - Ensures the opposite sign of amounts in base and quote.
        ///   - Ensures the sign of amounts in each position is consistent.
        /// - If base asset is active, validates the deleveraged position is deleveragable.
        /// - If base asset is inactive, it can always be deleveraged.
        ///
        /// Execution:
        /// - Update the position, based on `delevereged_base_asset`.
        /// - Adjust collateral balances based on `delevereged_quote_asset`.
        /// - Perform fundamental validation for both positions after the execution.
        fn deleverage(
            ref self: ContractState,
            operator_nonce: u64,
            deleveraged_position_id: PositionId,
            deleverager_position_id: PositionId,
            deleveraged_base_asset_id: AssetId,
            deleveraged_base_amount: i64,
            deleveraged_quote_asset_id: AssetId,
            deleveraged_quote_amount: i64,
        ) {
            /// Validations:
            self.pausable.assert_not_paused();
            self.operator_nonce.use_checked_nonce(:operator_nonce);
            self.assets.validate_assets_integrity();

            let deleveraged_position = self
                .positions
                .get_position_snapshot(position_id: deleveraged_position_id);
            let deleverager_position = self
                .positions
                .get_position_snapshot(position_id: deleverager_position_id);

            self
                ._validate_deleverage(
                    :deleveraged_position_id,
                    :deleverager_position_id,
                    :deleveraged_position,
                    :deleverager_position,
                    :deleveraged_base_asset_id,
                    :deleveraged_base_amount,
                    :deleveraged_quote_asset_id,
                    :deleveraged_quote_amount,
                );

            /// Execution:
            let deleveraged_position = self
                .positions
                .get_position_snapshot(position_id: deleveraged_position_id);
            let deleveraged_position_diff = self
                ._create_position_diff_from_asset_amounts(
                    position: deleveraged_position,
                    effective_quote: deleveraged_quote_amount.into(),
                    base_id: deleveraged_base_asset_id,
                    base_amount: deleveraged_base_amount.into(),
                );
            let deleverager_position = self
                .positions
                .get_position_snapshot(position_id: deleverager_position_id);

            let deleverager_position_diff = self
                ._create_position_diff_from_asset_amounts(
                    position: deleverager_position,
                    // Passing the negative of actual amounts to deleverager as it is linked to
                    // deleveraged.
                    effective_quote: -deleveraged_quote_amount.into(),
                    base_id: deleveraged_base_asset_id,
                    base_amount: -deleveraged_base_amount.into(),
                );

            /// Validations - Fundamentals:
            match self.assets.get_synthetic_config(deleveraged_base_asset_id).status {
                // If the synthetic asset is active, the position should be deleveragable
                // and changed to fair deleverage and healthier.
                AssetStatus::ACTIVE => {
                    self
                        ._validate_deleveraged_position(
                            position_id: deleveraged_position_id,
                            position: deleveraged_position,
                            position_diff: deleveraged_position_diff,
                            is_active_asset: true,
                        )
                },
                // In case of inactive synthetic asset, the position should changed to fair
                // deleverage and healthy or healthier.
                AssetStatus::INACTIVE => {
                    self
                        ._validate_deleveraged_position(
                            position_id: deleveraged_position_id,
                            position: deleveraged_position,
                            position_diff: deleveraged_position_diff,
                            is_active_asset: false,
                        )
                },
                // In case of pending synthetic asset, error should be thrown.
                AssetStatus::PENDING => panic_with_felt252(CANT_DELEVERAGE_PENDING_ASSET),
            }
            self
                ._validate_healthy_or_healthier_position(
                    position_id: deleverager_position_id,
                    position: deleverager_position,
                    position_diff: deleverager_position_diff,
                );

            // Apply diffs
            self
                .positions
                .apply_diff(
                    position_id: deleveraged_position_id, position_diff: deleveraged_position_diff,
                );
            self
                .positions
                .apply_diff(
                    position_id: deleverager_position_id, position_diff: deleverager_position_diff,
                );

            self
                .emit(
                    events::Deleverage {
                        deleveraged_position_id,
                        deleverager_position_id,
                        deleveraged_base_asset_id,
                        deleveraged_base_amount,
                        deleveraged_quote_asset_id,
                        deleveraged_quote_amount,
                    },
                )
        }
    }

    #[generate_trait]
    pub impl InternalCoreFunctions of InternalCoreFunctionsTrait {
        fn _create_collateral_position_diff(
            self: @ContractState, position: StoragePath<Position>, diff: Balance,
        ) -> PositionDiff {
            PositionDiff {
                collateral: self._compute_collateral_diff(:position, :diff),
                synthetic: Option::None,
            }
        }

        fn _compute_collateral_diff(
            self: @ContractState, position: StoragePath<Position>, diff: Balance,
        ) -> BalanceDiff {
            let before = self.positions.get_collateral_provisional_balance(:position);
            let after = before + diff;
            BalanceDiff { before, after }
        }

        fn _create_position_diff_from_asset_amounts(
            ref self: ContractState,
            position: StoragePath<Position>,
            effective_quote: Balance,
            base_id: AssetId,
            base_amount: Balance,
        ) -> PositionDiff {
            // Collateral asset.
            let collateral = self._compute_collateral_diff(:position, diff: effective_quote);

            // Synthetic asset.
            let before = self.positions.get_synthetic_balance(:position, synthetic_id: base_id);
            let after = before + base_amount;
            let synthetic = Option::Some(
                AssetDiff { id: base_id, balance: BalanceDiff { before, after } },
            );

            PositionDiff { collateral, synthetic }
        }

        fn _execute_transfer(
            ref self: ContractState,
            recipient: PositionId,
            position_id: PositionId,
            collateral_id: AssetId,
            amount: u64,
        ) {
            // Parameters
            let position = self.positions.get_position_snapshot(:position_id);
            let position_diff_sender = self
                ._create_collateral_position_diff(:position, diff: -(amount.into()));

            let recipient_position = self.positions.get_position_snapshot(position_id: recipient);
            let position_diff_recipient = self
                ._create_collateral_position_diff(
                    position: recipient_position, diff: amount.into(),
                );

            // Execute transfer
            self.positions.apply_diff(:position_id, position_diff: position_diff_sender);

            self
                .positions
                .apply_diff(position_id: recipient, position_diff: position_diff_recipient);

            /// Validations - Fundamentals:
            self
                ._validate_healthy_or_healthier_position(
                    :position_id, :position, position_diff: position_diff_sender,
                );
        }

        fn _update_fulfillment(
            ref self: ContractState,
            position_id: PositionId,
            hash: HashType,
            order_base_amount: i64,
            actual_base_amount: i64,
        ) {
            let fulfillment_entry = self.fulfillment.entry(hash);
            let total_amount = fulfillment_entry.read() + actual_base_amount.abs();
            assert_with_byte_array(
                total_amount <= order_base_amount.abs(), fulfillment_exceeded_err(:position_id),
            );
            fulfillment_entry.write(total_amount);
        }

        fn _validate_order(ref self: ContractState, order: Order) {
            // Verify that position is not fee position.
            assert(order.position_id != FEE_POSITION, CANT_TRADE_WITH_FEE_POSITION);

            // Non-zero amount check.
            assert(order.base_amount.is_non_zero(), INVALID_ZERO_AMOUNT);
            assert(order.quote_amount.is_non_zero(), INVALID_ZERO_AMOUNT);

            // Expiration check.
            let now = Time::now();
            assert_with_byte_array(now <= order.expiration, order_expired_err(order.position_id));

            // Sign Validation for amounts.
            assert(!have_same_sign(order.quote_amount, order.base_amount), INVALID_AMOUNT_SIGN);

            // Validate asset ids.
            let collateral_id = self.assets.get_collateral_id();
            assert(order.quote_asset_id == collateral_id, QUOTE_ASSET_ID_NOT_COLLATERAL);
            assert(order.fee_asset_id == collateral_id, QUOTE_ASSET_ID_NOT_COLLATERAL);
        }

        fn _validate_trade(
            ref self: ContractState,
            order_a: Order,
            order_b: Order,
            actual_amount_base_a: i64,
            actual_amount_quote_a: i64,
            actual_fee_a: u64,
            actual_fee_b: u64,
        ) {
            // Base asset check.
            assert(order_a.base_asset_id == order_b.base_asset_id, DIFFERENT_BASE_ASSET_IDS);
            self.assets.validate_synthetic_active(synthetic_id: order_a.base_asset_id);

            assert(order_a.position_id != order_b.position_id, INVALID_SAME_POSITIONS);

            self._validate_order(order: order_a);
            self._validate_order(order: order_b);

            // Non-zero actual amount check.
            assert(actual_amount_base_a != 0, INVALID_ZERO_AMOUNT);
            assert(actual_amount_quote_a != 0, INVALID_ZERO_AMOUNT);

            // Sign Validation for amounts.
            assert(
                !have_same_sign(order_a.quote_amount, order_b.quote_amount),
                INVALID_QUOTE_AMOUNT_SIGN,
            );
            assert(
                have_same_sign(order_a.base_amount, actual_amount_base_a), INVALID_ACTUAL_BASE_SIGN,
            );
            assert(
                have_same_sign(order_a.quote_amount, actual_amount_quote_a),
                INVALID_ACTUAL_QUOTE_SIGN,
            );

            order_a
                .validate_against_actual_amounts(
                    actual_amount_base: actual_amount_base_a,
                    actual_amount_quote: actual_amount_quote_a,
                    actual_fee: actual_fee_a,
                );
            order_b
                .validate_against_actual_amounts(
                    // Passing the negative of actual amounts to order_b as it is linked to order_a.
                    actual_amount_base: -actual_amount_base_a,
                    actual_amount_quote: -actual_amount_quote_a,
                    actual_fee: actual_fee_b,
                );
        }

        fn _validate_synthetic_shrinks(
            ref self: ContractState,
            position: StoragePath<Position>,
            asset_id: AssetId,
            amount: i64,
        ) {
            let position_base_balance: i64 = self
                .positions
                .get_synthetic_balance(:position, synthetic_id: asset_id)
                .into();

            assert(!have_same_sign(amount, position_base_balance), INVALID_AMOUNT_SIGN);
            assert(amount.abs() <= position_base_balance.abs(), INVALID_DELEVERAGE_BASE_CHANGE);
        }

        fn _validate_deleverage(
            ref self: ContractState,
            deleveraged_position_id: PositionId,
            deleverager_position_id: PositionId,
            deleveraged_position: StoragePath<Position>,
            deleverager_position: StoragePath<Position>,
            deleveraged_base_asset_id: AssetId,
            deleveraged_base_amount: i64,
            deleveraged_quote_asset_id: AssetId,
            deleveraged_quote_amount: i64,
        ) {
            // Validate positions.
            assert(deleveraged_position_id != deleverager_position_id, INVALID_SAME_POSITIONS);

            // Non-zero amount check.
            assert(deleveraged_base_amount.is_non_zero(), INVALID_ZERO_AMOUNT);
            assert(deleveraged_quote_amount.is_non_zero(), INVALID_ZERO_AMOUNT);

            // Assets check.
            assert(
                self.assets.is_synthetic(asset_id: deleveraged_base_asset_id),
                INVALID_NON_SYNTHETIC_ASSET,
            );

            // Sign Validation for amounts.
            assert(
                !have_same_sign(deleveraged_base_amount, deleveraged_quote_amount),
                INVALID_AMOUNT_SIGN,
            );

            // Ensure that TR does not increase and that the base amount retains the same sign.
            self
                ._validate_synthetic_shrinks(
                    position: deleveraged_position,
                    asset_id: deleveraged_base_asset_id,
                    amount: deleveraged_base_amount,
                );
            self
                ._validate_synthetic_shrinks(
                    position: deleverager_position,
                    asset_id: deleveraged_base_asset_id,
                    amount: -deleveraged_base_amount,
                );
        }

        fn _validate_order_signature(
            self: @ContractState,
            position: StoragePath<Position>,
            order: Order,
            signature: Signature,
        ) -> HashType {
            let public_key = position.get_owner_public_key();
            let msg_hash = order.get_message_hash(:public_key);
            validate_stark_signature(:public_key, :msg_hash, :signature);
            msg_hash
        }

        fn _validate_healthy_or_healthier_position(
            self: @ContractState,
            position_id: PositionId,
            position: StoragePath<Position>,
            position_diff: PositionDiff,
        ) {
            let position_unchanged_assets = self
                .positions
                .get_position_unchanged_assets(position: position, position_diff: position_diff);

            let position_diff_enriched = self
                .assets
                .enrich_position_diff(position_diff: position_diff);

            validate_position_is_healthy_or_healthier(
                :position_id, unchanged_assets: position_unchanged_assets, :position_diff_enriched,
            );
        }

        fn _validate_liquidated_position(
            self: @ContractState,
            position_id: PositionId,
            position: StoragePath<Position>,
            position_diff: PositionDiff,
        ) {
            let position_unchanged_assets = self
                .positions
                .get_position_unchanged_assets(position: position, position_diff: position_diff);

            let position_diff_enriched = self
                .assets
                .enrich_position_diff(position_diff: position_diff);

            liquidated_position_validations(
                :position_id, unchanged_assets: position_unchanged_assets, :position_diff_enriched,
            );
        }

        fn _validate_deleveraged_position(
            self: @ContractState,
            position_id: PositionId,
            position: StoragePath<Position>,
            position_diff: PositionDiff,
            is_active_asset: bool,
        ) {
            let position_unchanged_assets = self
                .positions
                .get_position_unchanged_assets(position: position, position_diff: position_diff);

            let position_diff_enriched = self
                .assets
                .enrich_position_diff(position_diff: position_diff);

            deleveraged_position_validations(
                :position_id,
                unchanged_assets: position_unchanged_assets,
                :position_diff_enriched,
                :is_active_asset,
            );
        }
    }
}
