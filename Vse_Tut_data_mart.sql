/* Проект «Разработка витрины и решение ad-hoc задач»
 * Цель проекта: подготовка витрины данных маркетплейса «ВсёТут»
 * и решение четырех ad hoc задач на её основе
*/



/* Часть 1. Разработка витрины данных
 * Запрос для создания витрины данных с использованием CTE 
*/
--Выделим топ 3 региона
WITH top_regions AS (                                        
    SELECT 
        u.region,
        COUNT(o.order_id) AS orders_count
    FROM ds_ecom.orders AS o
    JOIN ds_ecom.users AS u ON o.buyer_id = u.buyer_id
    WHERE o.order_status IN ('Доставлено', 'Отменено')
    GROUP BY u.region
    ORDER BY orders_count DESC
    LIMIT 3
),
--Фильтруем заказы по значению "Доставлено, Отменено" 
filtered_orders AS (
    SELECT
        o.order_id,
        o.buyer_id,
        u.user_id,
        u.region,
        o.order_status,
        o.order_purchase_ts
    FROM ds_ecom.orders AS o
    JOIN ds_ecom.users AS u ON o.buyer_id = u.buyer_id
    JOIN top_regions AS tr ON u.region = tr.region
    WHERE o.order_status IN ('Доставлено', 'Отменено')
),
--Суммируем доставку и стоимость товара 
order_costs AS (
    SELECT
        order_id,
        SUM(price + delivery_cost) AS total_cost
    FROM ds_ecom.order_items
    GROUP BY order_id
),
--Определеяем тип оплаты, использование промокодов
payments_orders AS (                                    
    SELECT
        op.order_id,
        MAX(CASE 
                WHEN op.payment_installments > 1 THEN 1
                ELSE 0
            END
           ) AS installments,
        MAX(CASE
                WHEN op.payment_type = 'Промокод' THEN 1
                ELSE 0
            END
           ) AS promo,
        MAX(CASE
                WHEN op.payment_sequential = fp.first_payment_seq
                 AND op.payment_type = 'Денежный перевод'
                THEN 1
                ELSE 0
            END
           ) AS used_money_transfer
    FROM ds_ecom.order_payments AS op
/* Здесь вложенный запрос, так как требуется определить, что денеженый перевод был совершен первым успешным платежем. Сделать это можно по полю payment_sequential,
 * но он не всегда равен 1, поэтому я сначала определяю минимальынй payment_sequential во вложенном запросе.
*/
    JOIN (
        SELECT
            order_id,
            MIN(payment_sequential) AS first_payment_seq
        FROM ds_ecom.order_payments
        GROUP BY order_id
    ) AS fp ON op.order_id = fp.order_id
    GROUP BY op.order_id
), 
--В этом запросе я вывожу id заказа и оценку, перед этим во вложенном запросе я фильтрую данные, так как в review_score есть оценки по 5-ти и по 50-ти бальной шкале
reviews_orders AS (
    SELECT
        order_id,
        review_score_fixed
    FROM (SELECT 
			order_id,
			CASE
            	WHEN review_score = 50 OR review_score = 5 THEN 5
           	    WHEN review_score = 40 OR review_score = 4 THEN 4
           	    WHEN review_score = 30 OR review_score = 3 THEN 3
         	    WHEN review_score = 20 OR review_score = 2 THEN 2
         	    WHEN review_score = 10 OR review_score = 1 THEN 1
          	    ELSE 0
			END AS review_score_fixed
		  FROM ds_ecom.order_reviews) AS rsf
)
--Основной запрос в котором я агрегирую все данные, в том числе полученные в CTE, что бы получить готовую витринну данных.
SELECT
    fo.user_id,
    fo.region,
    MIN(fo.order_purchase_ts) AS first_order_ts,
    MAX(fo.order_purchase_ts) AS last_order_ts,
    MAX(DATE(fo.order_purchase_ts)) - MIN(DATE(fo.order_purchase_ts)) AS lifetime,
    COUNT(DISTINCT fo.order_id) AS total_orders,
    AVG(ro.review_score_fixed) AS avg_order_rating,
    COUNT(ro.review_score_fixed) AS num_orders_with_rating,
    COUNT(CASE
            WHEN fo.order_status = 'Отменено'
            THEN 1
        END) AS num_canceled_orders,
    ROUND(COUNT(CASE
                WHEN fo.order_status = 'Отменено'
                THEN 1
            END)::NUMERIC / COUNT(DISTINCT fo.order_id), 2) AS canceled_orders_ratio,
    SUM(CASE
            WHEN fo.order_status = 'Доставлено'
            THEN oc.total_cost
            ELSE 0
        END) AS total_order_costs,
    AVG(CASE
            WHEN fo.order_status = 'Доставлено'
            THEN oc.total_cost
        END) AS avg_order_cost,
    SUM(po.installments) AS num_installment_orders,
    SUM(po.promo) AS num_orders_with_promo,
    MAX(po.used_money_transfer) AS used_money_transfer,
    MAX(po.installments) AS used_installments,
    MAX(CASE
            WHEN fo.order_status = 'Отменено'
            THEN 1
            ELSE 0
        END) AS used_cancel
FROM filtered_orders AS fo
LEFT JOIN order_costs AS oc ON fo.order_id = oc.order_id
LEFT JOIN payments_orders AS po ON fo.order_id = po.order_id
LEFT JOIN reviews_orders AS ro ON fo.order_id = ro.order_id
GROUP BY fo.user_id, fo.region
ORDER BY total_orders DESC
/* Часть 2. Решение ad hoc задач
 * Для каждой задачи написан отдельный запрос.
*/

/* Задача 1. Сегментация пользователей 
 * Разделите пользователей на группы по количеству совершённых ими заказов.
 * Подсчитайте для каждой группы общее количество пользователей,
 * среднее количество заказов, среднюю стоимость заказа.
 * 
 * Выделите такие сегменты:
 * - 1 заказ — сегмент 1 заказ
 * - от 2 до 5 заказов — сегмент 2-5 заказов
 * - от 6 до 10 заказов — сегмент 6-10 заказов
 * - 11 и более заказов — сегмент 11 и более заказов
*/

WITH segment AS (
	SELECT 
		user_id,
		CASE 
			WHEN total_orders = 1 THEN '1 заказ'
			WHEN total_orders BETWEEN 2 AND 5 THEN '2—5 заказов'
			WHEN total_orders BETWEEN 6 AND 10 THEN '6–10 заказов'
			WHEN total_orders >= 11 THEN '11 и более заказов'
			ELSE '0 заказов'
		END AS segment_users	
	FROM product_user_features
)
SELECT 
    s.segment_users,
	COUNT(puf.user_id) AS count_users,
	ROUND(AVG(puf.total_orders), 2) AS avg_orders,
	ROUND(SUM(total_order_costs) / SUM(total_orders), 2) AS avg_order_costs
FROM product_user_features AS puf
JOIN segment AS s ON puf.user_id = s.user_id
GROUP BY s.segment_users
ORDER BY count_users DESC

/* Краткий комментарий с выводами по результатам задачи 1.
 * Больше 95 процентов пользователей совершили один заказ, 5 человек сделали от 6 до 10 заказов и только один пользователь совершил более 10 заказов!
 * Так же, наблюдается интересная зависимость в сегментах, чем больше среднее количество заказов, тем меньше средняя стоимость заказа.
*/



/* Задача 2. Ранжирование пользователей 
 * Отсортируйте пользователей, сделавших 3 заказа и более, по убыванию среднего чека покупки.  
 * Выведите 15 пользователей с самым большим средним чеком среди указанной группы.
*/

SELECT 
	user_id,
	total_orders,
	avg_order_cost,
	ROW_NUMBER() OVER(ORDER BY avg_order_cost DESC)
FROM product_user_features
WHERE total_orders >= 3 AND avg_order_cost IS NOT NULL
LIMIT 15

/* Краткий комментарий с выводами по результатам задачи 2.
 * Разница между 1 и 15 местом по расходам почти в 3 раза, 14700 и 5500 соотвественно. Почти все пользователи совершили одинаковое колличество заказов - 3,
 * лишь у двох пользователей больше, 4 и 5 заказов
*/



/* Задача 3. Статистика по регионам. 
 * Для каждого региона подсчитайте:
 * - общее число клиентов и заказов;
 * - среднюю стоимость одного заказа;
 * - долю заказов, которые были куплены в рассрочку;
 * - долю заказов, которые были куплены с использованием промокодов;
 * - долю пользователей, совершивших отмену заказа хотя бы один раз.
*/

SELECT 
	region,
	COUNT(user_id) AS num_users,
	SUM(total_orders) AS num_orders,
	ROUND(SUM(total_order_costs) / SUM(total_orders), 2) AS avg_cost_per_order,
	ROUND(SUM(num_installment_orders)::NUMERIC / COUNT(user_id), 3) AS orders_purchased_installments_share,  
	ROUND(SUM(num_orders_with_promo)::NUMERIC / COUNT(user_id), 4) AS orders_purchased_promo_share,        
	ROUND(SUM(used_cancel)::NUMERIC / COUNT(user_id), 4) AS users_cancelled_order_share                      
FROM product_user_features
GROUP BY region

/* Краткий комментарий с выводами по результатам задачи 3.
 * В москве больше всего пользователей и заказов, около 65 процентов. Средняя сумма за заказ практически одинаковая.
 * При этом, чуть больше половины всех заказов оплачены при помощи рассрочки. Самая большая доля заказов с промокодом в Санкт Петербурге,
 * хоть и больше буквально на пол процента, чем в Москве или Новосибирской области. Самая большая доля отмен в Москве - 0.0082,
 * а самая низкая в Новосибирской области 0.0056, разница в полтора раза!
*/



/* Задача 4. Активность пользователей по первому месяцу заказа в 2023 году
 * Разбейте пользователей на группы в зависимости от того, в какой месяц 2023 года они совершили первый заказ.
 * Для каждой группы посчитайте:
 * - общее количество клиентов, число заказов и среднюю стоимость одного заказа;
 * - средний рейтинг заказа;
 * - долю пользователей, использующих денежные переводы при оплате;
 * - среднюю продолжительность активности пользователя.
*/

SELECT 
    EXTRACT(MONTH FROM first_order_ts) AS order_month,
    COUNT(DISTINCT user_id) AS count_users,
    SUM(total_orders) AS count_orders,
    ROUND(SUM(total_order_costs) / SUM(total_orders), 2) AS avg_order_cost,
    ROUND(AVG(avg_order_rating), 2) AS avg_order_rating,
    ROUND(SUM(used_money_transfer)::NUMERIC / COUNT(DISTINCT user_id)::NUMERIC, 3) AS users_using_money_transfer_share,
    AVG(lifetime) AS avg_lifetime
FROM product_user_features AS puf
WHERE EXTRACT(YEAR FROM first_order_ts) = 2023
GROUP BY EXTRACT(MONTH FROM first_order_ts)
ORDER BY order_month

/* Краткий комментарий с выводами по результатам задачи 4.
 * Больше всего первые заказы совершаются в ноябре и декабре, на эти 2 месяца так же приходится самое большое количество заказов,
 * а вот самый большой спад активности происходит в январе. В течении года такие показатели как: средняя стоимость заказа и доля
 * пользователей, использующих денежные переводы остается неизменной. С 1 по 7 месяц средний рейтинг почти не меняется и держится в районе 4.2, 
 * но на 8 и 9 месяце вырастает до 4.3 а затем к концу года стремительно падает до 4. Средняя продолжительность активности пользователя 
 * плавно снижается от начала года (12 дней) до конца года (2 дня)
*/